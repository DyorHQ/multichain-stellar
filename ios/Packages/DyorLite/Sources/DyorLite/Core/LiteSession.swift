import Foundation
import Observation
import StellarKit

/// The Stellar session of one signed-in DyorHQ account. The host makes one per account and keeps it across network
/// switches (design spec §2.6 rule 6): it holds the sign-in, the store with Stellar's last figures, and the setup run.
///
/// The setup run (spec §3.6.3) goes: a silent check of the server's config, not listed (a paused service, a build too
/// old for it or another sponsor fail here, before any prompt) → unlock (one prompt for the whole run) → sign in (the
/// first time, the server asks for an invite code and the run waits for it) → set up the account (the run waits for the
/// user's tap, which is the consent to the write). `plan()` says, without the network or a prompt, which of those a
/// switch needs.
///
/// The signer an unlock gives lives only in memory, for one run: it signs the sign-in, the sign-in again with an invite
/// (the server's nonce is single-use, so that needs a fresh signature) and the setup plan. It is dropped when the run
/// ends, on `cancel()`, after `idleTimeout` (120 s) while the run waits on the user, and on `appDidEnterBackground()`;
/// the next step that needs it unlocks again. It is never written anywhere. Every later transaction unlocks for itself
/// (`LiteKeyProvider.signer(reason:)`).
@MainActor
@Observable
public final class LiteSession {
    /// What one unlock gives: the account's key provider (its method, for the screens; it unlocks on demand) and the
    /// signer for this run.
    public struct UnlockResult: Sendable {
        public let keys: LiteKeyProvider
        public let signer: StellarSigner

        public init(keys: LiteKeyProvider, signer: StellarSigner) {
            self.keys = keys
            self.signer = signer
        }
    }

    /// A step of the setup run, as the network sheet lists it. `.invite` takes `.signIn`'s place while the server wants
    /// an invite code, and gives it back when the code is sent.
    public enum Step: Hashable, Sendable { case unlock, signIn, invite, setUp }

    public enum StepStatus: Equatable, Sendable { case pending, running, needsYou, done, failed(Failure) }

    /// Why a step or the run stopped. The host shows its own copy for each case; `errorDescription` is the package's.
    /// The host's `unlock` may throw one of these (`.keyNotOnDevice`, `.cancelled`, …) to say exactly what happened.
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case offline, cancelled, otherAccountsKey, keyNotOnDevice, paused, updateRequired,
             inviteRejected, accessRevoked, rateLimited, setUpFailed, server(String)

        /// Whether trying again can help. When it can't, the sheet shows Close instead of Try again (spec §4).
        public var canRetry: Bool {
            switch self {
            case .paused, .updateRequired, .accessRevoked, .keyNotOnDevice: false
            default: true
            }
        }

        public var errorDescription: String? {
            switch self {
            case .offline: tr("No connection. Check your network and try again.")
            case .cancelled: tr("Unlock was cancelled.")
            case .otherAccountsKey: tr("That passkey is for a different account. Use this account's passkey.")
            case .keyNotOnDevice: tr("Your Stellar key isn't on this iPhone yet. Sign in again on this iPhone to use Stellar.")
            case .paused: tr("DyorHQ on Stellar is paused for maintenance. Monad is unaffected.")
            case .updateRequired: tr("Update DyorHQ to use Stellar.")
            case .inviteRejected: tr("That code isn't valid, has expired or was already used.")
            case .accessRevoked: tr("Access to Stellar was turned off for this account.")
            case .rateLimited: tr("Too many tries. Wait a moment and try again.")
            case .setUpFailed: tr("Couldn't set up your Stellar account. Nothing was spent.")
            case .server(let message): message
            }
        }
    }

    public enum Plan: Equatable, Sendable { case instant, setup([Step]) }

    /// Where the session stands. `.failed(nil, _)` is the silent check failing (offline); `.unavailable` is the server
    /// refusing this build or pausing Stellar, and Stellar Home shows its paused card.
    public enum State: Equatable, Sendable {
        case idle, running, waiting(Step), ready, locked, unavailable(Failure), failed(Step?, Failure)
    }

    public struct StepRow: Identifiable, Equatable, Sendable {
        public let step: Step
        public let status: StepStatus
        public var id: Step { step }
    }

    // MARK: - What the host reads

    public private(set) var state: State = .idle
    /// The setup run's checklist: `plan()`'s steps, each with its status.
    public private(set) var steps: [StepRow] = []
    /// Non-nil once signed in (or a saved session restored), and kept while the session is locked, so a return to
    /// Stellar shows the last figures at once.
    public private(set) var store: LiteStore?
    /// True while the setup transaction is being sent: the sheet's ✕ and swipe-down stay off, and `cancel()` waits.
    public private(set) var isSending = false

    /// The account's Stellar address: given at init, or learned from the first unlock.
    private(set) var address: String?
    /// The account's key provider: the host's, or the last unlock's. Never a key: it names the method and unlocks on
    /// demand.
    private(set) var keys: LiteKeyProvider?
    /// What Stellar Home shows: the last settled state, kept while a run is under way or waits on the user.
    private(set) var home: HomePhase = .loading

    enum HomePhase: Equatable { case loading, ready, locked, paused(Failure) }

    // MARK: - Inside

    let env: LiteEnvironment
    let monad: LiteMonadBridge?
    @ObservationIgnored private let unlock: @Sendable (String) async throws -> UnlockResult
    @ObservationIgnored let backend: LiteBackend
    @ObservationIgnored let vault: LiteSessionVault
    @ObservationIgnored let defaults: UserDefaults
    /// The setup run's signer. Memory only.
    @ObservationIgnored private var signer: StellarSigner?
    @ObservationIgnored private(set) var config: LiteConfig?
    /// When the Stellar session ends, once this process signed in or restored it.
    @ObservationIgnored private var expiry: Date?
    /// Bumped by every action, `cancel()` and `signOut()`: work that comes back to an older one changes nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastAction: Action = .run
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    /// How long the signer waits on the user before it is dropped.
    @ObservationIgnored var idleTimeout: Duration = .seconds(120)
    @ObservationIgnored var now: () -> Date = Date.init

    private enum Action { case run, join(String), setUp }

    /// A switch is instant only while the session has this long left (spec §2.3).
    static let instantMargin: TimeInterval = 5 * 60
    /// A saved session is restored at launch only while it has this long left (the API's own margin).
    static let resumeMargin: TimeInterval = 60

    /// - Parameters:
    ///   - stellarAddress: the account's Stellar address when the host knows it (stored at a past unlock, sign-in or
    ///     import); nil before the first unlock derives it.
    ///   - monad: the account's Monad wallet, for the bridge.
    ///   - keys: the account's key provider when the host can make one without a prompt. Optional: without it the
    ///     Stellar account screen learns the method at the first unlock, and transactions unlock through `unlock`.
    ///   - unlock: one prompt (passkey, or Face ID and the Keychain), returning the provider and a signer for this
    ///     address. `reason` is in the current language. Throw a `Failure` to say exactly what went wrong
    ///     (`.keyNotOnDevice`, `.cancelled`); `KeyError.badMnemonic` reads as another account's key, `KeyError.badSeed`
    ///     as no key on this iPhone, and LocalAuthentication / passkey cancellations as `.cancelled`.
    public convenience init(env: LiteEnvironment, stellarAddress: String?, monad: LiteMonadBridge?, keys: LiteKeyProvider? = nil,
                            unlock: @escaping @Sendable (_ reason: String) async throws -> UnlockResult) {
        self.init(env: env, stellarAddress: stellarAddress, monad: monad, keys: keys,
                  backend: LiveBackend(api: LiteAPI(baseURL: env.apiURL), pinned: env.pinned),
                  vault: KeychainSessionVault(), defaults: .standard, unlock: unlock)
    }

    init(env: LiteEnvironment, stellarAddress: String?, monad: LiteMonadBridge?, keys: LiteKeyProvider?,
         backend: LiteBackend, vault: LiteSessionVault, defaults: UserDefaults,
         unlock: @escaping @Sendable (String) async throws -> UnlockResult) {
        self.env = env
        self.monad = monad
        self.keys = keys
        address = stellarAddress ?? keys?.address
        self.backend = backend
        self.vault = vault
        self.defaults = defaults
        self.unlock = unlock
    }

    // MARK: - Plan (local: no network, no prompt)

    /// What switching to Stellar needs now: nothing (`.instant`: the address is known, the session has 5 minutes or
    /// more left and the account was set up), or a setup run with these steps (spec §2.3). The invite step is found
    /// during the sign-in.
    public func plan() -> Plan {
        var steps: [Step] = []
        if !hasSession(for: Self.instantMargin) { steps = [.unlock, .signIn] }
        if !isActivated { steps.append(.setUp) }
        return steps.isEmpty ? .instant : .setup(steps)
    }

    // MARK: - The setup run

    /// check → [unlock] → [sign in] → [set up]. It pauses at `.waiting(.invite)` for `join(invite:)` and at
    /// `.waiting(.setUp)` for `setUp()`, and ends `.ready`. With nothing to do it only checks and restores, without a
    /// prompt. It does nothing while a run is under way or waits on the user.
    public func run() async {
        switch state {
        case .running, .waiting: return
        default: break
        }
        await perform(.run)
    }

    /// Sends the invite code: the sign-in again, signed with the run's key, then the account.
    public func join(invite code: String) async {
        switch state {
        case .waiting(.invite), .failed(.invite, _): await perform(.join(Self.normalized(code)))
        default: return
        }
    }

    /// Sets the account up: creates it and enables USDC (DyorHQ pays the fees and the reserve), signed with the run's
    /// key, then ends the run.
    public func setUp() async {
        switch state {
        case .waiting(.setUp), .failed(.setUp, _): await perform(.setUp)
        default: return
        }
    }

    /// Resumes at the failed step, unlocking first if the key was dropped. A rejected invite goes back to waiting for
    /// a code; a failed check, a paused service or a locked session start over.
    public func retry() async {
        switch state {
        case .failed(.invite, _):
            set(.invite, .needsYou)
            wait(.invite)
        case .failed(.setUp, _):
            await perform(.setUp)
        case .failed(.unlock, _), .failed(.signIn, _):
            await perform(lastAction)
        case .failed(nil, _), .unavailable, .idle, .locked:
            await perform(.run)
        case .running, .waiting, .ready:
            return
        }
    }

    /// Stops the run between steps or during a read, and drops the key. What finished stays: the address, a saved
    /// session, the account's setup. The state goes back to where it rested (`.idle`, `.locked`, `.ready` or
    /// `.unavailable`). Ignored while the setup transaction is being sent.
    public func cancel() {
        guard !isSending else { return }
        generation += 1
        dropSigner()
        state = resting
    }

    /// Restores a saved session without a prompt: `.ready` when one is saved with time left and the account was set up,
    /// else `.locked`. Then reads the server's config, silently: a paused service or a build too old for it make it
    /// `.unavailable`. Called at a cold launch on Stellar; `LiteRootView` calls it too when it appears idle.
    public func resumeAtLaunch() async {
        switch state {
        case .running, .waiting, .ready: return
        default: break
        }
        generation += 1
        let gen = generation
        if isActivated, let address, let saved = vault.load(account: address, network: network),
           saved.expiresAt > now().addingTimeInterval(Self.resumeMargin) {
            await backend.restore(token: saved.token, expiresAt: saved.expiresAt)
            guard gen == generation else { return }
            expiry = saved.expiresAt
            makeStore()
            settleReady()
        } else {
            state = .locked
            home = .locked
        }
        guard let config = try? await backend.config(), gen == generation else { return }
        if let failure = gate(config) { settle(unavailable: failure) } else { adopt(config) }
    }

    /// Ends the Stellar session on this iPhone: the saved session goes and the figures with it. The Stellar key stays
    /// where the account keeps it, and the account stays set up: the next switch unlocks and signs in again.
    public func signOut() async {
        generation += 1
        dropSigner()
        isSending = false
        if let address { vault.erase(account: address, network: network) }
        expiry = nil
        store = nil
        steps = []
        state = .locked
        home = .locked
        await backend.signOut()
    }

    /// The app went to the background (the host calls this on `scenePhase == .background`): the run's signer goes, and
    /// the next step that needs it unlocks again ("Unlock again to continue.").
    public func appDidEnterBackground() {
        guard signer != nil else { return }
        dropSigner(markPending: true)
    }

    // MARK: - Steps

    private func perform(_ action: Action) async {
        generation += 1
        let gen = generation
        idleTask?.cancel()
        lastAction = action
        state = .running
        switch action {
        case .run, .join:
            var invite: String?
            if case .join(let code) = action {
                invite = code
                if config == nil { guard await check(gen) else { return } }
            } else {
                steps = rows(for: plan())
                guard await check(gen) else { return }
            }
            // Signed in earlier in this run (Try again after the account couldn't be read): no second sign-in.
            if hasSession(for: Self.instantMargin) {
                await restoreSaved()
            } else {
                guard await ensureSigner(gen), await signIn(invite: invite, gen) else { return }
            }
            await readAccount(gen)
        case .setUp:
            if config == nil { guard await check(gen) else { return } }
            guard await ensureSigner(gen), let signer, let config else { return }
            await setUpAccount(signer: signer, config: config, gen)
        }
    }

    /// The silent check: the server's config, and whether it lets this build in.
    private func check(_ gen: Int) async -> Bool {
        do {
            let config = try await backend.config()
            guard gen == generation else { return false }
            if let failure = gate(config) {
                settle(unavailable: failure)
                return false
            }
            adopt(config)
            return true
        } catch {
            guard gen == generation else { return false }
            fail(nil, Self.failure(for: error))
            return false
        }
    }

    /// What the server's config says about this build: nil when it may go on.
    private func gate(_ config: LiteConfig) -> Failure? {
        if !config.flags.enabled { return .paused }
        if config.minBuild > env.buildNumber || config.sponsor != env.pinned.sponsor || config.network != env.pinned.network.name {
            return .updateRequired
        }
        return nil
    }

    /// The run's signer: the one already unlocked, or one prompt now.
    private func ensureSigner(_ gen: Int) async -> Bool {
        if signer != nil {
            set(.unlock, .done)
            return true
        }
        if !steps.contains(where: { $0.step == .unlock }) { steps.insert(StepRow(step: .unlock, status: .pending), at: 0) }
        set(.unlock, .running)
        do {
            let result = try await unlock(tr("Unlock your Stellar key"))
            guard gen == generation else { return false }
            guard result.signer.address == result.keys.address, address == nil || address == result.signer.address else {
                throw Failure.otherAccountsKey
            }
            address = result.signer.address
            keys = result.keys
            signer = result.signer
            set(.unlock, .done)
            return true
        } catch {
            guard gen == generation else { return false }
            fail(.unlock, Self.failure(for: error))
            return false
        }
    }

    /// Signs the server's single-use challenge with the run's key; `invite` the first time.
    private func signIn(invite: String?, _ gen: Int) async -> Bool {
        guard let signer else { return false }
        replace(.invite, with: .signIn)
        set(.signIn, .running)
        do {
            let result = try await backend.signIn(signer: signer, invite: invite)
            // A session the server issued is kept even if the run was cancelled meanwhile: it is work that finished.
            remember(result, for: signer.address)
            guard gen == generation else { return false }
            set(.signIn, .done)
            makeStore()
            return true
        } catch let error as LiteAPIError where error.code == "not_invited" {
            guard gen == generation else { return false }
            replace(.signIn, with: .invite)
            set(.invite, .needsYou)
            wait(.invite)
            return false
        } catch let error as LiteAPIError where error.code == "bad_invite" {
            guard gen == generation else { return false }
            replace(.signIn, with: .invite)
            fail(.invite, .inviteRejected)
            return false
        } catch {
            guard gen == generation else { return false }
            fail(.signIn, Self.failure(for: error))
            return false
        }
    }

    /// Whether the account is set up: done (the run ends), or the run waits for the user's tap on Set up.
    private func readAccount(_ gen: Int) async {
        do {
            let account = try await backend.account()
            guard gen == generation else { return }
            store?.adopt(account: account)
            if Self.isSetUp(account) {
                markActivated()
                set(.setUp, .done)
                finish()
            } else {
                if !steps.contains(where: { $0.step == .setUp }) { steps.append(StepRow(step: .setUp, status: .pending)) }
                set(.setUp, .needsYou)
                wait(.setUp)
            }
        } catch {
            guard gen == generation else { return }
            // Part of checking the access: Try again reads it again, and never writes before the user's tap.
            fail(steps.contains(where: { $0.step == .signIn }) ? .signIn : nil, Self.failure(for: error))
        }
    }

    private func setUpAccount(signer: StellarSigner, config: LiteConfig, _ gen: Int) async {
        set(.setUp, .running)
        isSending = true
        defer { isSending = false }
        do {
            try await backend.activate(signer: signer, config: config)
            let account = try await backend.account()
            guard gen == generation else { return }
            store?.adopt(account: account)
            guard Self.isSetUp(account) else { throw Failure.setUpFailed }
            markActivated()
            set(.setUp, .done)
            finish()
        } catch {
            guard gen == generation else { return }
            fail(.setUp, Self.setUpFailure(for: error))
        }
    }

    // MARK: - Settling

    private func finish() {
        dropSigner()
        // An unlock the run never needed (a saved session, an account already set up) isn't shown as done.
        steps.removeAll { $0.step == .unlock && $0.status == .pending }
        settleReady()
        if let store { Task { await store.refreshAll() } }
    }

    private func settleReady() {
        state = .ready
        home = .ready
    }

    private func settle(unavailable failure: Failure) {
        dropSigner()
        state = .unavailable(failure)
        home = .paused(failure)
    }

    private func wait(_ step: Step) {
        state = .waiting(step)
        startIdleTimer()
    }

    private func fail(_ step: Step?, _ failure: Failure) {
        if let step { set(step, .failed(failure)) }
        state = .failed(step, failure)
        if failure.canRetry { startIdleTimer() } else { dropSigner() }
    }

    private var resting: State {
        switch home {
        case .loading: .idle
        case .ready: .ready
        case .locked: .locked
        case .paused(let failure): .unavailable(failure)
        }
    }

    // MARK: - The signer's life

    private func dropSigner(markPending: Bool = false) {
        signer = nil
        idleTask?.cancel()
        idleTask = nil
        if markPending, let index = steps.firstIndex(where: { $0.step == .unlock }), steps[index].status == .done {
            steps[index] = StepRow(step: .unlock, status: .pending)
        }
    }

    /// While the run waits on the user, the signer stays `idleTimeout` at most.
    private func startIdleTimer() {
        idleTask?.cancel()
        guard signer != nil else { return }
        let gen = generation
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.idleExpired(gen)
        }
    }

    private func idleExpired(_ gen: Int) {
        guard gen == generation else { return }
        switch state {
        case .waiting, .failed: dropSigner(markPending: true)
        default: break
        }
    }

    /// Whether the run holds a signer (tests).
    var holdsSigner: Bool { signer != nil }

    // MARK: - Rows

    private func rows(for plan: Plan) -> [StepRow] {
        guard case .setup(let list) = plan else { return [] }
        return list.map { StepRow(step: $0, status: $0 == .unlock && signer != nil ? .done : .pending) }
    }

    private func set(_ step: Step, _ status: StepStatus) {
        guard let index = steps.firstIndex(where: { $0.step == step }) else { return }
        steps[index] = StepRow(step: step, status: status)
    }

    private func replace(_ step: Step, with other: Step) {
        guard let index = steps.firstIndex(where: { $0.step == step }) else { return }
        steps[index] = StepRow(step: other, status: steps[index].status)
    }

    // MARK: - Session, account and store

    private var network: String { env.pinned.network.name }

    private func hasSession(for margin: TimeInterval) -> Bool {
        guard let end = expiry ?? address.flatMap({ vault.load(account: $0, network: network)?.expiresAt }) else { return false }
        return end > now().addingTimeInterval(margin)
    }

    private func remember(_ result: AuthResult, for address: String) {
        guard let end = ISO8601DateFormatter.liteUI.date(from: result.expiresAt) ?? ISO8601DateFormatter().date(from: result.expiresAt) else { return }
        expiry = end
        vault.save(token: result.token, expiresAt: end, account: address, network: network)
    }

    /// A saved session this process hasn't restored yet, handed to the API.
    private func restoreSaved() async {
        if expiry == nil, let address, let saved = vault.load(account: address, network: network) {
            await backend.restore(token: saved.token, expiresAt: saved.expiresAt)
            expiry = saved.expiresAt
        }
        makeStore()
    }

    var isActivated: Bool { address.map { defaults.bool(forKey: Self.activatedKey($0)) } ?? false }

    /// Where "this account is set up" is cached, per Stellar address (spec §2.3). The host removes `lite.activated.*`
    /// at sign-out and erase.
    nonisolated static func activatedKey(_ address: String) -> String { "lite.activated.\(address)" }

    private func markActivated() {
        guard let address else { return }
        defaults.set(true, forKey: Self.activatedKey(address))
    }

    nonisolated static func isSetUp(_ account: AccountView) -> Bool {
        account.exists && (account.balances.first { $0.asset == "USDC" }?.enabled ?? false)
    }

    private func makeStore() {
        guard store == nil, let address else { return }
        let store = LiteStore(env: env, api: backend.api, address: address, monad: monad, config: config)
        store.session = self
        self.store = store
    }

    private func adopt(_ config: LiteConfig) {
        self.config = config
        store?.config = config
    }

    // MARK: - What the store reports

    /// A read found the session gone (401): Stellar Home locks; the next switch unlocks and signs in. Not while a run is
    /// under way: it is signing in anew, and a read that started before it says nothing about the new session.
    func lostSession() {
        switch state {
        case .running, .waiting: return
        default: break
        }
        expiry = nil
        if let address { vault.erase(account: address, network: network) }
        guard home == .ready else { return }
        home = .locked
        if state == .ready { state = .locked }
    }

    /// A read was refused because the account's access was turned off.
    func lostAccess() {
        guard home == .ready || state == .ready else { return }
        settle(unavailable: .accessRevoked)
    }

    /// The config a refresh read: a paused service or a build too old shows the paused card.
    func read(config: LiteConfig) {
        if let failure = gate(config) {
            if home == .ready { settle(unavailable: failure) }
        } else {
            adopt(config)
        }
    }

    /// Home's pull to refresh: a locked or paused session is looked at again (without a prompt), a ready one read again.
    func refreshHome() async {
        switch state {
        case .idle, .locked, .unavailable: await resumeAtLaunch()
        default: break
        }
        if state == .ready, let store { await store.refreshAll() }
    }

    /// A signer for a transaction, after the setup run: one prompt through the account's provider, or the host's
    /// unlock when no provider is known yet. Never the run's cached signer.
    func signer(reason: String) async throws -> StellarSigner {
        guard let address else { throw LiteAPIError.notSignedIn }
        if let keys {
            let signer = try await keys.signer(reason: reason)
            guard signer.address == address else { throw KeyError.badMnemonic }
            return signer
        }
        let result = try await unlock(reason)
        guard result.signer.address == address, result.keys.address == address else { throw KeyError.badMnemonic }
        keys = result.keys
        return result.signer
    }

    // MARK: - Errors

    nonisolated static func normalized(_ code: String) -> String {
        code.filter { !$0.isWhitespace }.uppercased()
    }

    /// An error as the run's failure: the server's codes (backend lite/index.ts, _shared/auth.ts, _shared/http.ts),
    /// the connection, the unlock.
    nonisolated static func failure(for error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if let key = error as? KeyError { return key == .badMnemonic ? .otherAccountsKey : .keyNotOnDevice }
        if let api = error as? LiteAPIError {
            switch api {
            case .transport: return .offline
            case let .server(_, code, message, _):
                switch code {
                case "bad_invite": return .inviteRejected
                case "access_revoked": return .accessRevoked
                case "rate_limited": return .rateLimited
                default: return .server(message)
                }
            case .notSignedIn, .decoding: return .server(api.errorDescription ?? "")
            }
        }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .offline }
        if (ns.domain == "com.apple.LocalAuthentication" && [-2, -4, -9].contains(ns.code)) // userCancel, systemCancel, appCancel
            || (ns.domain == "com.apple.AuthenticationServices.AuthorizationError" && ns.code == 1001) // canceled
            || (ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError) {
            return .cancelled
        }
        return .server((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// A setup that didn't go through: the connection and the server's refusals as such, its own messages (Friendbot
    /// being slow) as they are, and anything about the transaction itself as "Couldn't set up…".
    nonisolated static func setUpFailure(for error: Error) -> Failure {
        if error is PlanRunner.Failure { return .setUpFailed }
        if case LiteAPIError.decoding = error { return .setUpFailed }
        return failure(for: error)
    }
}

// MARK: - The server and the saved session, as the session uses them

/// The Lite API calls the session makes (a test double stands in for it).
protocol LiteBackend: Sendable {
    /// The API the store reads and builds through, sharing the session's sign-in.
    var api: LiteAPI { get }
    func config() async throws -> LiteConfig
    func restore(token: String, expiresAt: Date) async
    func signIn(signer: StellarSigner, invite: String?) async throws -> AuthResult
    func account() async throws -> AccountView
    /// Creates the account (Friendbot on testnet) and runs the plan that enables USDC, if the server returns one.
    func activate(signer: StellarSigner, config: LiteConfig) async throws
    func signOut() async
}

struct LiveBackend: LiteBackend {
    let api: LiteAPI
    let pinned: PinnedContracts

    /// Reads made while someone watches the checklist: offline after this long (spec §4).
    static let readTimeout: TimeInterval = 10

    func config() async throws -> LiteConfig { try await api.config(timeout: Self.readTimeout) }
    func restore(token: String, expiresAt: Date) async { await api.restore(token: token, expiresAt: expiresAt) }

    func signIn(signer: StellarSigner, invite: String?) async throws -> AuthResult {
        try await api.signIn(signer: signer, inviteCode: invite, timeout: Self.readTimeout)
    }

    func account() async throws -> AccountView { try await api.account(timeout: Self.readTimeout) }

    func activate(signer: StellarSigner, config: LiteConfig) async throws {
        // Friendbot can take 20 s on testnet: the activation keeps the API's long timeout.
        let result = try await api.activate()
        guard let plan = result.plan else { return }
        guard let rpc = URL(string: config.rpcUrl) else { throw LiteAPIError.decoding("the RPC URL") }
        let runner = PlanRunner(api: api, user: signer.address, pinned: pinned, inspector: ContractInspector(rpcURL: rpc))
        try await runner.run(plan, limits: [:], signer: { signer })
    }

    func signOut() async { await api.signOut() }
}

/// Where the Stellar session token is kept between launches (not a key: it only reads and builds).
protocol LiteSessionVault: Sendable {
    func load(account: String, network: String) -> (token: String, expiresAt: Date)?
    func save(token: String, expiresAt: Date, account: String, network: String)
    func erase(account: String, network: String)
}

/// The Keychain (`StellarKeychain`): this device only, never synced.
struct KeychainSessionVault: LiteSessionVault {
    func load(account: String, network: String) -> (token: String, expiresAt: Date)? {
        #if canImport(Security)
        StellarKeychain.session(account: account, network: network)
        #else
        nil
        #endif
    }

    func save(token: String, expiresAt: Date, account: String, network: String) {
        #if canImport(Security)
        try? StellarKeychain.saveSession(token: token, expiresAt: expiresAt, account: account, network: network)
        #endif
    }

    func erase(account: String, network: String) {
        #if canImport(Security)
        StellarKeychain.eraseSession(account: account, network: network)
        #endif
    }
}
