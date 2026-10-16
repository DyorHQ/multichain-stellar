import Foundation
import Observation
import StellarKit

/// The Stellar session of one signed-in DyorHQ account. The host makes one per account and keeps it across network
/// switches (design spec §2.6 rule 6): it holds the sign-in, the store with Stellar's last figures, and the setup run.
///
/// Nothing on Stellar is gated (docs/DESIGN-stellar-parity.md §1.1 decision 6, §7.2). An account set up on this iPhone
/// is `.ready` at once at every launch, whatever became of its session, and reads keep working without one: the API's
/// viewer routes answer the public view of the account. The session renews itself in the background (§6.18): its
/// refresh token first, then, for a seed account (its Stellar seed is in this iPhone's Keychain), a silent sign-in that
/// signs only the sign-in challenge (§5.8); a passkey account with neither reads in the public view until the user
/// starts an action or taps Sign in. Prompts come only with a signature: the setup's, an action's (App Lock once when it
/// applies, or the passkey), or showing the secret key.
///
/// The setup run (§8.14) goes: a silent check of the server's config (a paused service, a build too old for it or
/// another sponsor fail here, before any prompt), then
/// - a seed account: sign in (silent) → the invite code when the server asks for one (nothing is held while it waits)
///   → the account → the Set Up tap, which is the consent to the write → App Lock when it applies → activate and enable;
/// - a passkey account: the Set Up tap first (with the invite code on a first sign-in, where one is needed) → one
///   passkey ceremony, whose signer signs the sign-in and, with no wait on the user in between, the account's setup, and
///   is dropped. Going to the background ends such a run ("Not finished. Try again.").
///
/// `plan()` says, without the network or a prompt, which of those a switch needs.
@MainActor
@Observable
public final class LiteSession {
    /// What a passkey account's setup ceremony gives (`setupKey`): the account's key provider and the signer for that
    /// one run.
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
    public enum Step: Hashable, Sendable {
        case signIn, invite, setUp
        /// Never listed: nothing unlocks any more (decision 6). It stays only so the app's network sheet, which still
        /// names it, compiles until it is ported (WP-22), and goes with it.
        @available(*, deprecated, message: "Nothing unlocks any more (decision 6): the session never lists this step.")
        case unlock
    }

    public enum StepStatus: Equatable, Sendable { case pending, running, needsYou, done, failed(Failure) }

    /// Why a step or the run stopped. The host shows its own copy for each case; `errorDescription` is the package's.
    /// The host's key provider and setup ceremony may throw one of these (`.keyNotOnDevice`, `.cancelled`, …) to say
    /// exactly what happened.
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
            case .cancelled: tr("Not finished. Try again.")
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

    /// Where the setup run stands. `.failed(nil, _)` is the silent check failing (offline); `.unavailable` is the server
    /// refusing this build or pausing Stellar, and Stellar Home shows its paused card. There is no locked state.
    public enum State: Equatable, Sendable {
        case idle, running, waiting(Step), ready, unavailable(Failure), failed(Step?, Failure)
    }

    /// What Stellar Home shows: the last settled state, kept while a run is under way or waits on the user.
    public enum HomePhase: Equatable, Sendable { case loading, ready, paused(Failure) }

    /// How the account is read: with a session (DyorHQ's own history included), or in the public view, which needs
    /// none and shows only what is on chain.
    public enum Access: Equatable, Sendable { case session, publicView }

    public struct StepRow: Identifiable, Equatable, Sendable {
        public let step: Step
        public let status: StepStatus
        public var id: Step { step }
    }

    // MARK: - What the host reads

    public private(set) var state: State = .idle
    /// The setup run's checklist: `plan()`'s steps, each with its status.
    public private(set) var steps: [StepRow] = []
    /// The account's figures and actions: made once the account's address is known, kept across network switches.
    public private(set) var store: LiteStore?
    /// True while the setup transaction is being sent: the sheet's ✕ and swipe-down stay off, and `cancel()` waits.
    public private(set) var isSending = false
    public private(set) var home: HomePhase = .loading
    /// `.session` whenever a session is held; `.publicView` while there is none.
    public private(set) var access: Access = .publicView
    /// The account's Stellar address: given at init, or learned from a passkey account's first setup ceremony.
    public private(set) var address: String?
    public let env: LiteEnvironment
    /// Markets and prices, which need no session and no account: Top Tokens and the token pages read them.
    public let publicReads: LitePublicReads
    /// The setup's Enable USDC step, priced (§8.14): its estimate (`/v1/fees`) before the Set Up tap, then its own
    /// transaction's fee once the server has built it. Its `newReserves` × `baseReserve` is what the step holds back.
    public private(set) var setupFee: PlanFees?
    /// The ledger's base reserve in stroops (0.5 XLM today), from `/v1/fees`; nil until read.
    public private(set) var baseReserve: Int64?
    /// Fires once for every plan the store settles, from the store's own task: a sheet that has closed doesn't stop it.
    @ObservationIgnored public var onSettled: (@MainActor (LiteSettledAction) -> Void)?
    /// Fires after `signOut()` with the account's Stellar address, for the host to erase what it saved for it.
    @ObservationIgnored public var onSignOut: (@MainActor (String) -> Void)?

    /// "Passkey", "Email", … for the account screen; nil until the account's key provider is known.
    public var methodLabel: String? { keys?.methodLabel }
    public var canExportSecret: Bool { keys?.canExportSecret ?? false }
    /// Whether the key can sign on this iPhone: false for watch-only, never because of a session.
    public var canSign: Bool { keys?.canSign ?? false }
    public var isTestnet: Bool { env.pinned.network != .mainnet }
    /// Whether a first sign-in needs an invite code (mainnet); older servers always ask for one.
    public var inviteRequired: Bool { config?.inviteRequired ?? true }

    // MARK: - Inside

    let monad: LiteMonadBridge?
    /// The account's key provider: the host's, or the one a passkey account's first setup ceremony gave. Never a key:
    /// it names the method and signs on demand.
    private(set) var keys: LiteKeyProvider?
    /// A passkey account's one setup ceremony (the host's).
    @ObservationIgnored private let setupKey: (@Sendable (String) async throws -> UnlockResult)?
    /// A Privy account's key provider, found the first time (the host's): its Stellar wallet is looked up, or made, with
    /// no prompt, and checked by the host before it is given.
    @ObservationIgnored private let resolveKeys: (@Sendable () async throws -> LiteKeyProvider)?
    @ObservationIgnored let backend: LiteBackend
    @ObservationIgnored let vault: LiteSessionVault
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private(set) var config: LiteConfig?
    @ObservationIgnored private(set) var fees: StellarFees?
    /// When the session's access token ends, once one is held.
    @ObservationIgnored private var expiry: Date?
    /// When that token was issued, for one this session got itself (a sign-in or a refresh): its lifetime bounds how
    /// long before its end it renews (`lead`). Nil for one a past launch saved.
    @ObservationIgnored private var issuedAt: Date?
    /// Whether a refresh token is held: the session can come back without the user, even for a passkey account.
    @ObservationIgnored private var refreshHeld = false
    /// Bumped by every run, `cancel()` and `signOut()`: work that comes back to an older one changes nothing.
    @ObservationIgnored private var generation = 0
    /// Bumped by `signOut()`: a sign-in or a refresh that started before it keeps nothing.
    @ObservationIgnored private var sessionEpoch = 0
    @ObservationIgnored private var lastAction: Action = .run
    @ObservationIgnored private var renewal: Task<Void, Error>?
    @ObservationIgnored private var renewalTimer: Task<Void, Never>?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var apiReady = false
    /// A passkey account's setup run's signer, while that run lasts. Memory only.
    @ObservationIgnored private var runSigner: SignerBox?
    @ObservationIgnored var now: () -> Date = Date.init

    private enum Action { case run, join(String), setUp(String?) }

    /// The session renews this long before its access token ends, while the app is in front (§6.18); a token that lasts
    /// less than twice as long renews half-way through instead (`lead`).
    static let renewalLead: TimeInterval = 10 * 60
    /// After a renewal that couldn't reach the server, the next try, while the app is in front.
    static let renewalRetry: TimeInterval = 60
    /// The soonest the timer renews again after a renewal went through, whatever the new token says: one renewal never
    /// starts the next at once.
    static let renewalFloor: TimeInterval = 30
    /// Reads made while someone watches the checklist: offline after this long (spec §4).
    static let readTimeout: TimeInterval = 10
    /// A sign-in or a refresh: a little longer, they are two requests or one that rotates.
    static let authTimeout: TimeInterval = 20

    /// - Parameters:
    ///   - stellarAddress: the account's Stellar address when the host knows it (stored at a sign-in, an import or a
    ///     past setup); nil for a passkey account before its first setup ceremony derives it.
    ///   - monad: the account's Monad wallet, for the bridge.
    ///   - keys: the account's key provider, when the host can make one without a prompt.
    ///   - setupKey: a passkey account's setup ceremony: one passkey prompt, returning the provider and a signer for
    ///     this address, which signs the sign-in and the account's setup and is then dropped. `reason` is in the current
    ///     language. Throw a `Failure` to say exactly what went wrong (`.keyNotOnDevice`, `.cancelled`);
    ///     `KeyError.badMnemonic` reads as another account's key, and passkey cancellations as `.cancelled`.
    ///   - resolveKeys: a Privy account's provider, the first time, when the host has none yet (`keys` nil): its
    ///     Stellar wallet looked up through the Lite API (`/v1/privy/wallet`) and checked by the host, with no prompt.
    ///     Asked only where the server serves Privy wallets (`LiteConfig.privyWallets`); the run then goes on as a seed
    ///     account's.
    public convenience init(env: LiteEnvironment, stellarAddress: String?, monad: LiteMonadBridge?, keys: LiteKeyProvider?,
                            setupKey: (@Sendable (_ reason: String) async throws -> UnlockResult)? = nil,
                            resolveKeys: (@Sendable () async throws -> LiteKeyProvider)? = nil) {
        self.init(env: env, stellarAddress: stellarAddress, monad: monad, keys: keys, setupKey: setupKey, resolveKeys: resolveKeys,
                  backend: LiveBackend(api: LiteAPI(baseURL: env.apiURL, network: env.pinned.network.name), pinned: env.pinned),
                  vault: KeychainSessionVault(), defaults: .standard)
    }

    /// The session as hosts made it before decision 6: `unlock` was every account's one prompt per setup run. It is now
    /// the setup ceremony of an account whose provider can't sign by itself.
    @available(*, deprecated, message: "Pass a passkey account's setup ceremony as setupKey (decision 6).")
    public convenience init(env: LiteEnvironment, stellarAddress: String?, monad: LiteMonadBridge?, keys: LiteKeyProvider? = nil,
                            unlock: @escaping @Sendable (_ reason: String) async throws -> UnlockResult) {
        self.init(env: env, stellarAddress: stellarAddress, monad: monad, keys: keys, setupKey: unlock)
    }

    init(env: LiteEnvironment, stellarAddress: String?, monad: LiteMonadBridge?, keys: LiteKeyProvider?,
         setupKey: (@Sendable (String) async throws -> UnlockResult)?, resolveKeys: (@Sendable () async throws -> LiteKeyProvider)? = nil,
         backend: LiteBackend, vault: LiteSessionVault, defaults: UserDefaults) {
        self.env = env
        self.monad = monad
        self.keys = keys
        self.setupKey = setupKey
        self.resolveKeys = resolveKeys
        address = stellarAddress ?? keys?.address
        self.backend = backend
        self.vault = vault
        self.defaults = defaults
        publicReads = LitePublicReads(api: backend.api)
    }

    var api: LiteAPI { backend.api }

    // MARK: - Plan (local: no network, no prompt)

    /// What switching to Stellar needs now: nothing (`.instant`) for an account set up on this iPhone, whatever became
    /// of its session; only the sign-in after Sign out of Stellar; otherwise the sign-in and the setup (§8.14). The
    /// invite step is found during the sign-in.
    public func plan() -> Plan {
        guard let address, isActivated(address) else { return .setup([.signIn, .setUp]) }
        return isSignedOut(address) ? .setup([.signIn]) : .instant
    }

    // MARK: - The setup run

    /// check → [sign in] → [the account] → [set up]. A seed account signs in silently and pauses at `.waiting(.invite)`
    /// for `join(invite:)` and at `.waiting(.setUp)` for `setUp()`; a passkey account pauses at `.waiting(.setUp)` first,
    /// before its one ceremony. It ends `.ready`. It does nothing while a run is under way or waits on the user.
    public func run() async {
        switch state {
        case .running, .waiting: return
        default: break
        }
        await perform(.run)
    }

    /// Sends the invite code: the sign-in again (a seed account's silently, a passkey account's with a new ceremony:
    /// the run kept nothing while it waited), then the account.
    public func join(invite code: String) async {
        switch state {
        case .waiting(.invite), .failed(.invite, _): await perform(.join(Self.normalized(code)))
        default: return
        }
    }

    /// The Set Up tap, which is the consent to the write: a seed account's App Lock when it applies, then the account's
    /// activation and Enable USDC; a passkey account's one ceremony, its sign-in and then the same, with no wait between.
    public func setUp() async {
        await setUp(invite: nil)
    }

    /// `setUp()`, with the invite code a passkey account's first sign-in on this iPhone may need (seed accounts send
    /// theirs with `join(invite:)`).
    public func setUp(invite code: String?) async {
        switch state {
        case .waiting(.setUp), .failed(.setUp, _): await perform(.setUp(code.map(Self.normalized).flatMap { $0.isEmpty ? nil : $0 }))
        default: return
        }
    }

    /// Resumes at the failed step. A rejected invite goes back to waiting for a code; a failed check or a paused service
    /// start over.
    public func retry() async {
        switch state {
        case .failed(.invite, _):
            set(.invite, .needsYou)
            state = .waiting(.invite)
        case .failed(.setUp, _):
            await perform(signsInSilently ? .setUp(nil) : lastAction)
        case .failed(.signIn, _):
            await perform(lastAction)
        case .failed, .unavailable, .idle:
            await perform(.run)
        case .running, .waiting, .ready:
            return
        }
    }

    /// Stops the run between steps or during a read. What finished stays: the address, a saved session, the account's
    /// setup. The state goes back to where it rested (`.idle`, `.ready` or `.unavailable`). Ignored while the setup
    /// transaction is being sent.
    public func cancel() {
        guard !isSending else { return }
        generation += 1
        dropRunSigner()
        state = resting
    }

    /// At a cold launch on Stellar (`LiteRootView` calls it too when it appears): an account set up on this iPhone is
    /// `.ready` at once, from what this iPhone saved, and never prompts; the server's config is read silently (a paused
    /// service or a build too old for it shows the paused card), and the session renews in the background when it is
    /// gone or ends within 10 minutes. An account that isn't set up here, or signed out, only gets the check: its next
    /// switch runs the setup.
    public func resumeAtLaunch() async {
        switch state {
        case .running, .waiting, .ready: return
        default: break
        }
        generation += 1
        let gen = generation
        await prepareAPI()
        guard gen == generation else { return }
        guard let address, isActivated(address), !isSignedOut(address) else {
            _ = await check(gen, quietly: true)
            return
        }
        let wasPaused = state != .idle
        await restoreSaved()
        guard gen == generation else { return }
        makeStore()
        // Ready at once, from what this iPhone saved; a paused service is read again first.
        if !wasPaused { settleReady() }
        guard await check(gen, quietly: true) else { return }
        if state != .ready { settleReady() }
        await renewIfDue()
    }

    /// Signs in: a seed account silently (§5.8), a passkey account with one ceremony used for the sign-in only. Called
    /// when a passkey account with no session starts an action, or taps a history part's "Sign in with your passkey".
    public func signIn() async throws {
        await prepareAPI()
        if let keys, keys.signsInSilently {
            try await silentSignIn(invite: nil)
        } else {
            let box = try await ceremony(reason: tr("Sign in to DyorHQ on Stellar"))
            defer { release(box) }
            try await signIn(with: box, invite: nil)
        }
        if let address, isActivated(address), state == .idle {
            makeStore()
            settleReady()
        }
        scheduleRenewal()
    }

    /// The app came to the front (the host calls this on `scenePhase == .active`): the session renews if it is gone or
    /// ends within 10 minutes (half a token's lifetime, for a token that lasts less than 20), and the renewal timer runs
    /// again. Never a prompt.
    public func appDidBecomeActive() {
        isActive = true
        guard home == .ready else { return }
        Task { await renewIfDue() }
    }

    /// The app went to the background (the host calls this on `scenePhase == .background`): the renewal timer stops,
    /// and a passkey account's setup run ends with its signer ("Not finished. Try again."). Nothing else is held.
    public func appDidEnterBackground() {
        isActive = false
        renewalTimer?.cancel()
        renewalTimer = nil
        guard let box = runSigner, box.holdsSigner else { return }
        dropRunSigner()
        // A sign-in outside the setup run only loses its signer (it then throws `.cancelled`).
        guard state == .running else { return }
        generation += 1
        isSending = false
        let step = steps.first { $0.status == .running }?.step ?? .setUp
        set(step, .failed(.cancelled))
        state = .failed(step, .cancelled)
    }

    /// Home's pull to refresh: a paused or idle session is looked at again (without a prompt), a ready one read again,
    /// after a silent renewal if it has no session.
    public func refreshHome() async {
        switch state {
        case .idle, .unavailable: await resumeAtLaunch()
        default: break
        }
        guard state == .ready, let store else { return }
        if access == .publicView, canRenewSilently { try? await renew() }
        await store.refreshAll()
    }

    /// The account's Stellar secret (S…): always the device owner's check, whatever App Lock says.
    public func revealSecret(reason: String) async throws -> String {
        guard let keys, let address else { throw Failure.keyNotOnDevice }
        do {
            return try await keys.revealSecret(reason: reason)
        } catch LiteKeyProviderDefault.noSigningRun {
            // A provider written before signing runs: the host's ceremony, as before.
            guard let setupKey else { throw Failure.keyNotOnDevice }
            let result = try await setupKey(reason)
            guard result.signer.address == address else { throw KeyError.badMnemonic }
            return result.signer.secret
        }
    }

    /// Ends the Stellar session on this iPhone: the refresh token's family is revoked (best effort), the saved session
    /// goes and the figures with it, and the next switch signs in again (silently for a seed account, one passkey
    /// prompt for a passkey account). The Stellar key stays where the account keeps it, and the account stays set up.
    public func signOut() async {
        generation += 1
        sessionEpoch += 1
        dropRunSigner()
        isSending = false
        renewalTimer?.cancel()
        renewalTimer = nil
        // Signed out from here on: no renewal starts for the account (`performRenewal`), and one under way keeps nothing
        // it brings back.
        if let address { defaults.set(true, forKey: Self.signedOutKey(address)) }
        expiry = nil
        issuedAt = nil
        refreshHeld = false
        access = .publicView
        store = nil
        steps = []
        state = .idle
        home = .loading
        // That renewal ends before the API's session goes, so whatever it rotated or signed in goes with it.
        if let renewal { _ = await renewal.result }
        let saved = address.flatMap { vault.load(account: $0, network: network) }
        let refresh = await api.refreshToken ?? saved?.refreshToken
        await api.signOut()
        if let refresh { await api.revoke(refreshToken: refresh) }
        if let address {
            vault.erase(account: address, network: network)
            onSignOut?(address)
        }
    }

    // MARK: - Steps

    private func perform(_ action: Action) async {
        generation += 1
        let gen = generation
        lastAction = action
        state = .running
        await prepareAPI()
        switch action {
        case .run:
            steps = rows(for: plan())
            guard await check(gen) else { return }
            guard await resolveKeysIfNeeded(gen) else { return }
            // A session an earlier launch saved (a setup that stopped after its sign-in) spares a second sign-in.
            if expiry == nil { await restoreSaved() }
            guard gen == generation else { return }
            if hasSession {
                // Signed in earlier (Try again after the account couldn't be read): no second sign-in.
                set(.signIn, .done)
                await readAccount(gen)
            } else if signsInSilently {
                guard await signInStep(invite: nil, gen) else { return }
                await readAccount(gen)
            } else if setupKey == nil {
                fail(.signIn, .keyNotOnDevice)
            } else if let address, isActivated(address) {
                // Set up already (this iPhone signed out): one ceremony, for the sign-in only.
                await passkeyRun(invite: nil, gen)
            } else {
                // A passkey account's first setup waits for the Set Up tap; nothing is held while it waits.
                if !steps.contains(where: { $0.step == .setUp }) { steps.append(StepRow(step: .setUp, status: .pending)) }
                set(.setUp, .needsYou)
                state = .waiting(.setUp)
            }
        case .join(let code):
            if config == nil { guard await check(gen) else { return } }
            guard await resolveKeysIfNeeded(gen) else { return }
            if signsInSilently {
                guard await signInStep(invite: code, gen) else { return }
                await readAccount(gen)
            } else {
                await passkeyRun(invite: code, gen)
            }
        case .setUp(let code):
            if config == nil { guard await check(gen) else { return } }
            guard await resolveKeysIfNeeded(gen) else { return }
            if signsInSilently || hasSession {
                await seedSetUp(gen)
            } else {
                await passkeyRun(invite: code, gen)
            }
        }
    }

    /// The silent check: the server's config, and whether it lets this build in; the network fees, for the setup's
    /// price. `quietly`: a failure to reach it changes nothing (a launch), else it fails the run.
    private func check(_ gen: Int, quietly: Bool = false) async -> Bool {
        do {
            let config = try await api.config(timeout: Self.readTimeout)
            guard gen == generation else { return false }
            if let failure = gate(config) {
                settle(unavailable: failure)
                return false
            }
            adopt(config)
            await readFees()
            return gen == generation
        } catch {
            guard gen == generation else { return false }
            if !quietly { fail(nil, Self.failure(for: error)) }
            return quietly
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

    /// The fees `/v1/fees` gives (public): the setup's estimate and the base reserve. Without them the setup has no
    /// price before its plan is built, and the plan's own transaction prices it.
    private func readFees() async {
        guard let fees = try? await api.fees(timeout: Self.readTimeout) else { return }
        self.fees = fees
        store?.adopt(fees: fees)
        baseReserve = Int64(fees.baseReserve)
        if setupFee == nil || setupFee?.steps.contains(where: \.built) == false {
            setupFee = Self.setupEstimate(fees: fees, pinned: env.pinned)
        }
    }

    /// A Privy account's first run: its provider, from the host's `resolveKeys` (the wallet looked up and checked, no
    /// prompt), as the sign-in step's first part. From then on the run is a seed account's: a silent sign-in. Where the
    /// server serves no Privy wallets the step fails with that, and nothing is asked. True when the run may go on.
    private func resolveKeysIfNeeded(_ gen: Int) async -> Bool {
        guard keys == nil, let resolveKeys else { return true }
        replace(.invite, with: .signIn)
        guard config?.privyWallets == true else {
            fail(.signIn, Self.privyWalletsUnavailable)
            return false
        }
        set(.signIn, .running)
        do {
            let provider = try await resolveKeys()
            guard gen == generation else { return false }
            guard address == nil || address == provider.address else { throw Failure.otherAccountsKey }
            keys = provider
            if address == nil {
                address = provider.address
                await api.setViewer(address: provider.address)
            }
            return gen == generation
        } catch {
            guard gen == generation else { return false }
            fail(.signIn, Self.failure(for: error))
            return false
        }
    }

    /// The server serves no Privy wallets (now): said as the API's `privy_unavailable` is.
    public nonisolated static var privyWalletsUnavailable: Failure {
        .server(tr("Stellar isn't available for this sign-in right now. Try again later."))
    }

    /// A seed account's sign-in step: silent, with `invite` the first time where one is needed.
    private func signInStep(invite: String?, _ gen: Int) async -> Bool {
        replace(.invite, with: .signIn)
        set(.signIn, .running)
        do {
            try await silentSignIn(invite: invite)
            guard gen == generation else { return false }
            set(.signIn, .done)
            return true
        } catch {
            guard gen == generation else { return false }
            signInFailed(error)
            return false
        }
    }

    /// A refused sign-in, as the checklist says it: the invite step when the server asks for a code.
    private func signInFailed(_ error: Error) {
        if let api = error as? LiteAPIError, api.code == "not_invited" {
            replace(.signIn, with: .invite)
            set(.invite, .needsYou)
            state = .waiting(.invite)
        } else if let api = error as? LiteAPIError, api.code == "bad_invite" {
            replace(.signIn, with: .invite)
            fail(.invite, .inviteRejected)
        } else {
            fail(steps.contains { $0.step == .invite } ? .invite : .signIn, Self.failure(for: error))
        }
    }

    /// A passkey account's run: one ceremony, whose signer signs the sign-in and, when the account isn't set up yet,
    /// its setup, with no wait on the user in between; then the signer is dropped. The prompt says which it is: an
    /// account set up on this iPhone (signed out of Stellar since) only signs in.
    private func passkeyRun(invite: String?, _ gen: Int) async {
        replace(.invite, with: .signIn)
        set(.signIn, .running)
        let signsInOnly = address.map(isActivated) ?? false
        let box: SignerBox
        do {
            box = try await ceremony(reason: signsInOnly ? tr("Sign in to DyorHQ on Stellar") : tr("Set up your Stellar account"))
        } catch {
            guard gen == generation else { return }
            fail(.signIn, Self.failure(for: error))
            return
        }
        defer { release(box) }
        guard gen == generation else { return }
        do {
            try await signIn(with: box, invite: invite)
        } catch {
            guard gen == generation else { return }
            signInFailed(error)
            return
        }
        guard gen == generation else { return }
        set(.signIn, .done)
        guard let account = await setupAccount(gen) else { return }
        if Self.isSetUp(account) {
            completeSetUp()
            return
        }
        await activate(signer: { try box.signer() }, gen)
    }

    /// A seed account's Set Up: App Lock when it applies (as a Monad Confirm), then the activation and Enable USDC, each
    /// signature read from the Keychain for itself.
    private func seedSetUp(_ gen: Int) async {
        set(.setUp, .running)
        let run: LiteSigningRun
        do {
            run = try await beginSigning(reason: tr("Set up your Stellar account"))
        } catch {
            guard gen == generation else { return }
            fail(.setUp, Self.failure(for: error))
            return
        }
        defer { run.end() }
        guard gen == generation else { return }
        await activate(signer: { try await run.signer(reason: tr("Enable USDC")) }, gen)
    }

    /// Creates the account (Friendbot on testnet, DyorHQ's sponsor on mainnet) and runs the plan that enables USDC, at
    /// no more than the fee shown before the tap; then the account must read as set up.
    private func activate(signer: @escaping @Sendable () async throws -> any StellarHashSigner, _ gen: Int) async {
        guard let address else { return }
        set(.setUp, .running)
        isSending = true
        defer { isSending = false }
        let confirmed = setupFee
        let sent = SentFlag()
        do {
            // Friendbot can take 20 s on testnet: the activation keeps the API's long timeout.
            let result = try await api.activate()
            if let plan = result.plan {
                let priced = try PlanFees(plan: plan, pinned: env.pinned, estimates: fees)
                let fees = try Self.confirmed(priced, plan: plan, by: confirmed, pinned: env.pinned)
                guard gen == generation else { return }
                // The step's own figure once it exists (its decoded fee when built), never above the one shown.
                setupFee = fees
                _ = try await backend.run(plan, user: address, limits: [:], fees: fees, signer: signer, onEvent: { event in
                    if case .submitted = event { sent.mark() }
                })
            }
            let account = try await api.account(timeout: Self.readTimeout)
            guard gen == generation else { return }
            store?.adopt(account: account)
            guard Self.isSetUp(account) else { throw Failure.setUpFailed }
            completeSetUp()
        } catch {
            guard gen == generation else { return }
            fail(.setUp, Self.setUpFailure(for: error, sent: sent.value))
        }
    }

    /// The account, after the sign-in: set up already (the run ends), or waiting for the user's tap on Set Up.
    private func readAccount(_ gen: Int) async {
        guard let account = await setupAccount(gen) else { return }
        if Self.isSetUp(account) {
            completeSetUp()
        } else {
            if !steps.contains(where: { $0.step == .setUp }) { steps.append(StepRow(step: .setUp, status: .pending)) }
            set(.setUp, .needsYou)
            state = .waiting(.setUp)
        }
    }

    /// The account read during the run; nil when the read failed (the run failed) or the run moved on.
    private func setupAccount(_ gen: Int) async -> AccountView? {
        do {
            let account = try await api.account(timeout: Self.readTimeout)
            guard gen == generation else { return nil }
            makeStore()
            store?.adopt(account: account)
            return account
        } catch {
            guard gen == generation else { return nil }
            // Part of checking the access: Try again reads it again, and never writes before the user's tap.
            fail(steps.contains(where: { $0.step == .signIn }) ? .signIn : nil, Self.failure(for: error))
            return nil
        }
    }

    // MARK: - Signing in

    /// A seed account's silent sign-in: the provider signs only the sign-in challenge, with no prompt (§5.8). `epoch`:
    /// the session it belongs to (a renewal's, which a sign-out may have ended meanwhile); the current one by default.
    private func silentSignIn(invite: String?, epoch: Int? = nil) async throws {
        guard let keys, let address else { throw Failure.keyNotOnDevice }
        let epoch = epoch ?? sessionEpoch
        let result = try await api.signIn(address: address, inviteCode: invite, timeout: Self.authTimeout) { message in
            try await keys.signInSignature(for: message)
        }
        try await keep(result, for: address, epoch: epoch)
    }

    /// The passkey ceremony (`setupKey`): its signer, in a box the run drops when it ends or the app leaves.
    private func ceremony(reason: String) async throws -> SignerBox {
        guard let setupKey else { throw keys == nil ? Failure.keyNotOnDevice : Failure.needsPasskey }
        let result = try await setupKey(reason)
        guard result.signer.address == result.keys.address, address == nil || address == result.signer.address else {
            throw Failure.otherAccountsKey
        }
        if address == nil {
            address = result.signer.address
            await api.setViewer(address: result.signer.address)
        }
        keys = result.keys
        let box = SignerBox(result.signer)
        runSigner?.drop()
        runSigner = box
        return box
    }

    /// Signs in with the run's signer: the sign-in challenge, as SEP-53.
    private func signIn(with box: SignerBox, invite: String?) async throws {
        let signer = try box.signer()
        let epoch = sessionEpoch
        let result = try await api.signIn(address: signer.address, inviteCode: invite, timeout: Self.authTimeout) { message in
            try box.signer().signMessage(message)
        }
        try await keep(result, for: signer.address, epoch: epoch)
    }

    /// A sign-in's session, kept for `address`. One that came back after Sign out of Stellar ended the session it was for
    /// (`epoch`) is revoked instead, and the API forgets it unless a newer one replaced it: the sign-in then didn't happen
    /// (`.cancelled`).
    private func keep(_ result: AuthResult, for address: String, epoch: Int) async throws {
        guard epoch == sessionEpoch else {
            if await api.token == result.token { await api.signOut() }
            if let refresh = result.refreshToken { await api.revoke(refreshToken: refresh) }
            throw Failure.cancelled
        }
        remember(result, for: address, epoch: epoch)
        await api.setViewer(address: address)
    }

    /// The run is over: its signer goes.
    private func release(_ box: SignerBox) {
        box.drop()
        if runSigner === box { runSigner = nil }
    }

    private func dropRunSigner() {
        runSigner?.drop()
        runSigner = nil
    }

    /// Whether a setup run holds a signer now (tests): only a passkey account's, only while its run lasts.
    var holdsSigner: Bool { runSigner?.holdsSigner ?? false }

    // MARK: - Signing an action

    /// The signing of one confirmed action (`LiteStore.run`): the provider's run, where App Lock is asked once when it
    /// applies (seed accounts) and the passkey once per signature (passkey accounts). Every signer it gives is checked
    /// to be the account's.
    func beginSigning(reason: String) async throws -> LiteSigningRun {
        guard let keys, let address else { throw Failure.keyNotOnDevice }
        guard keys.canSign else { throw KeyError.badSeed }
        let run: LiteSigningRun
        do {
            run = try await keys.beginSigning(reason: reason)
        } catch LiteKeyProviderDefault.noSigningRun {
            // A provider written before signing runs: the host's ceremony, one per signature, as before.
            guard let setupKey else { throw Failure.keyNotOnDevice }
            run = CeremonySigningRun(ceremony: setupKey)
        }
        return AccountSigningRun(run, address: address)
    }

    /// Before an action is built or run: a session, silently where it can be had silently, otherwise (a passkey account
    /// with no refresh token) one passkey sign-in. The user started the action, so the prompt is theirs.
    func ensureSession() async throws {
        await prepareAPI()
        if access == .session, !needsRenewal { return }
        if canRenewSilently { try? await renew() }
        // A session with time left still serves (the API renews it on a 401); none at all needs the sign-in.
        if access == .session, hasSession { return }
        try await signIn()
    }

    /// Whether the history parts need the passkey to read: a passkey account in the public view with no refresh token.
    var needsSignIn: Bool { access == .publicView && !canRenewSilently }

    // MARK: - Renewal (§6.18)

    /// Whether a session can come back with no one asked: a refresh token, or a seed account's silent sign-in.
    var canRenewSilently: Bool { refreshHeld || signsInSilently }

    private var signsInSilently: Bool { keys?.signsInSilently ?? false }

    /// How long before its access token ends the session renews: 10 minutes, or half the token's lifetime when it lasts
    /// less than 20 (QA's 120-second tokens, §6.14), so that a fresh token is never due at once. A token a past launch
    /// saved has no known lifetime: 10 minutes.
    var lead: TimeInterval {
        guard let expiry, let issuedAt else { return Self.renewalLead }
        return min(Self.renewalLead, max(0, expiry.timeIntervalSince(issuedAt)) / 2)
    }

    /// No session, or one that ends within `lead`.
    private var needsRenewal: Bool {
        guard let expiry else { return true }
        return expiry < now().addingTimeInterval(lead)
    }

    /// At launch and on becoming active: a renewal now when one is due and can be had (a refresh token, a seed account's
    /// silent sign-in, or a session to keep), else the timer for the one that will be. A renewal's outcome times the
    /// next itself: the new token's (`remember`), a retry after one that couldn't reach the server, or none when it found
    /// no way back. Never a prompt.
    private func renewIfDue() async {
        guard needsRenewal, canRenewSilently || access == .session else { return scheduleRenewal() }
        _ = try? await renew()
    }

    /// Renews the session, never with a prompt: the refresh token first, then a seed account's silent sign-in; with
    /// neither, the public view. One renewal at a time: the timer's, a 401's (through the API) and Home's share it.
    func renew() async throws {
        if let renewal { return try await renewal.value }
        let task = Task { try await self.performRenewal() }
        renewal = task
        defer { if renewal == task { renewal = nil } }
        try await task.value
    }

    /// The renewal. An account signed out of Stellar has none: only its next sign-in brings a session back. One that
    /// was under way when it signed out (`sessionEpoch` moved on) keeps nothing it brings back, starts no sign-in in its
    /// refresh's place and changes nothing else.
    private func performRenewal() async throws {
        guard let address, !isSignedOut(address) else { throw LiteAPIError.notSignedIn }
        let epoch = sessionEpoch
        // The refresh token the API holds now, not a copy: a refresh rotates it.
        if let refresh = await api.refreshToken {
            do {
                let result = try await api.refresh(address: address, refreshToken: refresh, timeout: Self.authTimeout)
                remember(result, for: address, epoch: epoch)
                return
            } catch let error as LiteAPIError where Self.isRefusedRefresh(error) {
                guard epoch == sessionEpoch else { throw error }
                refreshHeld = false
                if error.code == "access_revoked" {
                    lostAccess()
                    throw error
                }
            } catch {
                // Offline: what is saved stays, and the next try comes soon.
                if epoch == sessionEpoch { keepAfterFailedRenewal() }
                throw error
            }
        }
        guard epoch == sessionEpoch else { throw LiteAPIError.notSignedIn }
        if signsInSilently {
            do {
                try await silentSignIn(invite: nil, epoch: epoch)
                return
            } catch {
                guard epoch == sessionEpoch else { throw error }
                if case LiteAPIError.transport = error {
                    keepAfterFailedRenewal()
                    throw error
                }
                if (error as? LiteAPIError)?.code == "access_revoked" { lostAccess() }
                await goPublic()
                throw error
            }
        }
        await goPublic()
        throw LiteAPIError.notSignedIn
    }

    /// The server refused the refresh token itself (unknown, used or expired; or access turned off): renewing it again
    /// can't help.
    private static func isRefusedRefresh(_ error: LiteAPIError) -> Bool {
        switch error {
        case .notSignedIn: return true
        case let .server(status, code, _, _): return status == 401 || status == 403 || code.hasPrefix("refresh_")
        case .transport, .decoding: return false
        }
    }

    /// No session left: reads go on in the public view. The saved session is dead, so it goes, here and in the API
    /// (its token would only earn a 401).
    private func goPublic() async {
        access = .publicView
        expiry = nil
        issuedAt = nil
        refreshHeld = false
        if let address { vault.erase(account: address, network: network) }
        await api.signOut()
    }

    /// A renewal that couldn't reach the server: a token that hasn't ended is still the session.
    private func keepAfterFailedRenewal() {
        if let expiry, expiry <= now() { access = .publicView }
        scheduleRenewal(after: Self.renewalRetry)
    }

    /// While the app is in front: a renewal `lead` before the access token ends, but no sooner than `soonest` seconds
    /// from now (`renewalFloor` after a renewal went through); or exactly `after` seconds from now, to try again after
    /// one that couldn't reach the server. Without a session there is nothing to renew ahead of its end.
    private func scheduleRenewal(after delay: TimeInterval? = nil, soonest: TimeInterval = 0) {
        renewalTimer?.cancel()
        renewalTimer = nil
        guard isActive, home == .ready, canRenewSilently || access == .session, delay != nil || expiry != nil else { return }
        let due = (expiry ?? now()).addingTimeInterval(-lead).timeIntervalSince(now())
        let wait = delay ?? max(soonest, due)
        let gen = generation
        renewalTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, wait)))
            guard !Task.isCancelled, let self, gen == self.generation, self.isActive else { return }
            if (try? await self.renew()) != nil { self.scheduleRenewal(soonest: Self.renewalFloor) }
        }
    }

    /// The renewal the API runs on a 401, and the account its public view is about. Once per session object.
    func prepareAPI() async {
        guard !apiReady else { return }
        apiReady = true
        await api.setRenewal { [weak self] in
            guard let self else { throw LiteAPIError.notSignedIn }
            try await self.renew()
        }
        if let address { await api.setViewer(address: address) }
    }

    // MARK: - Settling

    private func completeSetUp() {
        markActivated()
        set(.setUp, .done)
        finish()
    }

    private func finish() {
        dropRunSigner()
        if let address { defaults.removeObject(forKey: Self.signedOutKey(address)) }
        makeStore()
        settleReady()
        scheduleRenewal()
        if let store { Task { await store.refreshAll() } }
    }

    private func settleReady() {
        state = .ready
        home = .ready
    }

    private func settle(unavailable failure: Failure) {
        dropRunSigner()
        state = .unavailable(failure)
        home = .paused(failure)
    }

    private func fail(_ step: Step?, _ failure: Failure) {
        if let step { set(step, .failed(failure)) }
        state = .failed(step, failure)
        dropRunSigner()
    }

    private var resting: State {
        switch home {
        case .loading: .idle
        case .ready: .ready
        case .paused(let failure): .unavailable(failure)
        }
    }

    // MARK: - Rows

    private func rows(for plan: Plan) -> [StepRow] {
        guard case .setup(let list) = plan else { return [] }
        return list.map { StepRow(step: $0, status: .pending) }
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

    /// Whether a session is held now: an access token that hasn't ended.
    private var hasSession: Bool {
        guard let expiry else { return false }
        return expiry > now()
    }

    private func remember(_ result: AuthResult, for address: String, epoch: Int) {
        guard epoch == sessionEpoch, let end = result.expiresAt.liteDate else { return }
        expiry = end
        issuedAt = now()
        let refreshEnd = result.refreshExpiresAt?.liteDate
        refreshHeld = result.refreshToken != nil
        access = .session
        defaults.removeObject(forKey: Self.signedOutKey(address))
        vault.save(LiteSavedSession(token: result.token, expiresAt: end, refreshToken: result.refreshToken, refreshExpiresAt: refreshEnd),
                   account: address, network: network)
        // The timer follows the token in hand, whichever renewal brought it (the timer's, a 401's, an action's).
        scheduleRenewal(soonest: Self.renewalFloor)
    }

    /// The session this iPhone saved, handed to the API with its refresh token; the account is the viewer either way.
    private func restoreSaved() async {
        guard let address else { return }
        if let saved = vault.load(account: address, network: network) {
            await api.restore(token: saved.token, expiresAt: saved.expiresAt, refreshToken: saved.refreshToken, refreshExpiresAt: saved.refreshExpiresAt)
            expiry = saved.expiresAt
            issuedAt = nil
            refreshHeld = saved.refreshToken != nil
            access = saved.expiresAt > now() ? .session : .publicView
        } else {
            access = .publicView
        }
        await api.setViewer(address: address)
    }

    func isActivated(_ address: String) -> Bool { defaults.bool(forKey: Self.activatedKey(address)) }
    func isSignedOut(_ address: String) -> Bool { defaults.bool(forKey: Self.signedOutKey(address)) }

    /// Where "this account is set up on this iPhone" is cached, per Stellar address (spec §2.3). The host removes
    /// `lite.activated.*` at sign-out and erase.
    public nonisolated static func activatedKey(_ address: String) -> String { "lite.activated.\(address)" }

    /// Set by Sign out of Stellar, cleared by the next sign-in: the next switch signs in again. The host removes
    /// `lite.signedOut.*` with `lite.activated.*`.
    public nonisolated static func signedOutKey(_ address: String) -> String { "lite.signedOut.\(address)" }

    private func markActivated() {
        guard let address else { return }
        defaults.set(true, forKey: Self.activatedKey(address))
    }

    nonisolated static func isSetUp(_ account: AccountView) -> Bool {
        account.exists && (account.balances.first { $0.asset == "USDC" }?.enabled ?? false)
    }

    private func makeStore() {
        guard store == nil, let address else { return }
        let store = LiteStore(env: env, backend: backend, address: address, monad: monad, config: config)
        store.session = self
        if let fees { store.adopt(fees: fees) }
        self.store = store
    }

    private func adopt(_ config: LiteConfig) {
        self.config = config
        store?.config = config
    }

    // MARK: - What the store reports

    /// A read was refused because the account's access was turned off: the paused card.
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

    // MARK: - The setup's price

    /// The Enable USDC step as `/v1/fees` prices it before its plan exists: one user-paid trust step at its estimate,
    /// holding one more base reserve.
    nonisolated static func setupEstimate(fees: StellarFees, pinned: PinnedContracts) -> PlanFees? {
        guard let estimate = fees.estimate("trust") ?? StellarFeeDefaults.estimate("trust") else { return nil }
        let step: [String: Any] = ["id": "trust", "label": "Enable USDC", "status": "pending", "stepKind": "trust",
                                   "maxFee": String(estimate), "feePayer": "user", "reserveDelta": 1]
        let plan: [String: Any] = ["planId": "setup", "kind": "trust", "expiresAt": "", "steps": [step]]
        guard let data = try? JSONSerialization.data(withJSONObject: plan),
              let view = try? JSONDecoder().decode(PlanView.self, from: data) else { return nil }
        return try? PlanFees(plan: view, pinned: pinned)
    }

    /// The fees the setup plan runs with: no step above the fee the user saw before the Set Up tap. A step built at
    /// once that costs more is refused before anything is signed; one built later must fit the figure that was shown.
    nonisolated static func confirmed(_ priced: PlanFees, plan: PlanView, by shown: PlanFees?, pinned: PinnedContracts) throws -> PlanFees {
        guard let shown else { return priced }
        let cap: (String?) -> Int64? = { kind in kind.flatMap { k in shown.steps.first { $0.stepKind == k }?.maxFee } }
        for step in priced.steps where step.built {
            if let max = cap(step.stepKind), step.maxFee > max {
                throw PlanRunner.Failure.feeAboveConfirmed(step: plan.steps.first { $0.id == step.id }?.label ?? step.id)
            }
        }
        let above = priced.steps.contains { step in
            guard !step.built, let max = cap(step.stepKind) else { return false }
            return step.maxFee > max
        }
        guard above else { return priced }
        return try PlanFees(plan: plan.capping(cap), pinned: pinned)
    }

    // MARK: - Errors

    nonisolated static func normalized(_ code: String) -> String {
        code.filter { !$0.isWhitespace }.uppercased()
    }

    /// An error as the run's failure: the server's codes (backend lite/index.ts, _shared/auth.ts, _shared/http.ts),
    /// the connection, the ceremony.
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
                // A Privy account's wallet and signatures (/v1/privy/*), in this build's words.
                case "privy_unavailable", "privy_refused", "privy_bad_signature", "privy_token_invalid":
                    return .server(LiteErrorText.describe(api))
                default: return .server(message)
                }
            case .notSignedIn, .decoding: return .server(LiteErrorText.describe(api))
            }
        }
        if error is CancellationError { return .cancelled }
        if error is StellarSigningError { return .server(LiteErrorText.describe(error)) }
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
    /// being slow) as they are. Before anything was sent (`sent`), a refusal of the transaction itself is "Couldn't set
    /// up… Nothing was spent." Once a step reached the network that is never said: the user pays the Enable USDC step's
    /// fee (§4.1), and a step not confirmed yet may still land. Then it is what Stellar said about the step, or that the
    /// account doesn't read as set up yet.
    nonisolated static func setUpFailure(for error: Error, sent: Bool = false) -> Failure {
        switch error {
        case let runner as PlanRunner.Failure:
            switch runner {
            case .failedOnChain, .timedOut: return .server(LiteErrorText.describe(runner))
            case .refused, .overLimit, .feeAboveConfirmed: return sent ? .server(LiteErrorText.describe(runner)) : .setUpFailed
            }
        case LiteAPIError.decoding:
            return sent ? .server(LiteErrorText.describe(error)) : .setUpFailed
        case Failure.setUpFailed where sent:
            return .server(tr("Your Stellar account isn't ready yet. Try again in a moment."))
        default:
            return failure(for: error)
        }
    }
}

public extension LiteSession.Failure {
    /// Only the account's passkey can sign in: its provider can't sign the challenge without a prompt (a passkey or
    /// watch-only account). `LiteKeyProvider.signInSignature(for:)` throws it; the session then reads in the public view,
    /// and asks for the passkey only when the user starts an action or taps Sign in. Not a case of its own yet: the app's
    /// network sheet switches over every case (WP-22 ports it).
    static var needsPasskey: Self { .server(tr("Sign in with your passkey to continue.")) }
}

// MARK: - Signers in runs

/// A passkey setup run's signer, held for that run only: dropped when the run ends, is cancelled or the app leaves.
final class SignerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var held: StellarSigner?

    init(_ signer: StellarSigner) { held = signer }

    var holdsSigner: Bool { lock.withLock { held != nil } }

    /// The signer, or `.cancelled` once the run let it go.
    func signer() throws -> StellarSigner {
        guard let signer = lock.withLock({ held }) else { throw LiteSession.Failure.cancelled }
        return signer
    }

    func drop() { lock.withLock { held = nil } }
}

/// Whether a run sent a step (`PlanRunner.Event.submitted`): from then on its fee may be spent.
private final class SentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false

    var value: Bool { lock.withLock { sent } }
    func mark() { lock.withLock { sent = true } }
}

/// A run for a provider written before signing runs: the host's setup ceremony once per signature (transitional).
final class CeremonySigningRun: LiteSigningRun {
    private let ceremony: @Sendable (String) async throws -> LiteSession.UnlockResult
    private let ended = SigningRunEnd()

    init(ceremony: @escaping @Sendable (String) async throws -> LiteSession.UnlockResult) {
        self.ceremony = ceremony
    }

    func signer(reason: String) async throws -> any StellarHashSigner {
        try ended.check()
        return try await ceremony(reason).signer
    }

    func end() { ended.end() }
}

/// A provider's run, each signer checked to be the account's before it signs anything.
final class AccountSigningRun: LiteSigningRun {
    private let run: LiteSigningRun
    private let address: String

    init(_ run: LiteSigningRun, address: String) {
        self.run = run
        self.address = address
    }

    func signer(reason: String) async throws -> any StellarHashSigner {
        let signer = try await run.signer(reason: reason)
        guard signer.address == address else { throw KeyError.badMnemonic }
        return signer
    }

    func end() { run.end() }
}

// MARK: - The server and the saved session, as the session uses them

/// What the session and the store send through besides the API's own calls: a plan's run (a test double runs plans
/// without a chain).
protocol LiteBackend: Sendable {
    /// The API the session signs in, renews and reads through, and the store builds through.
    var api: LiteAPI { get }
    /// Verifies, signs and sends a plan's steps for `user`, within `limits` and the `fees` the user confirmed.
    func run(_ plan: PlanView, user: String, limits: [String: Int64], fees: PlanFees,
             signer: @Sendable () async throws -> any StellarHashSigner, onEvent: @Sendable (PlanRunner.Event) -> Void) async throws -> [TxStatus]
}

struct LiveBackend: LiteBackend {
    let api: LiteAPI
    let pinned: PinnedContracts

    /// `PlanRunner` with launch tokens checked on the build's pinned RPC (§5.5), never the one the server names.
    func run(_ plan: PlanView, user: String, limits: [String: Int64], fees: PlanFees,
             signer: @Sendable () async throws -> any StellarHashSigner, onEvent: @Sendable (PlanRunner.Event) -> Void) async throws -> [TxStatus] {
        let runner = PlanRunner(api: api, user: user, pinned: pinned, inspector: ContractInspector(pinned: pinned))
        return try await runner.run(plan, limits: limits, fees: fees, signer: signer, onEvent: onEvent)
    }
}

/// Where the Stellar session is kept between launches: its access token and the refresh token that renews it (not
/// keys: a session only reads and builds).
protocol LiteSessionVault: Sendable {
    func load(account: String, network: String) -> LiteSavedSession?
    func save(_ session: LiteSavedSession, account: String, network: String)
    func erase(account: String, network: String)
}

/// The Keychain (`StellarKeychain`): this device only, never synced.
struct KeychainSessionVault: LiteSessionVault {
    func load(account: String, network: String) -> LiteSavedSession? {
        #if canImport(Security)
        guard let session = StellarKeychain.session(account: account, network: network) else { return nil }
        let refresh = StellarKeychain.refreshToken(account: account, network: network)
        return LiteSavedSession(token: session.token, expiresAt: session.expiresAt, refreshToken: refresh?.token, refreshExpiresAt: refresh?.expiresAt)
        #else
        nil
        #endif
    }

    func save(_ session: LiteSavedSession, account: String, network: String) {
        #if canImport(Security)
        try? StellarKeychain.saveSession(token: session.token, expiresAt: session.expiresAt, refreshToken: session.refreshToken,
                                         refreshExpiresAt: session.refreshExpiresAt, account: account, network: network)
        #endif
    }

    func erase(account: String, network: String) {
        #if canImport(Security)
        StellarKeychain.eraseSession(account: account, network: network)
        #endif
    }
}

extension PlanView {
    /// The plan with every unbuilt step's ceiling no higher than `cap` for its kind: the step must be built within it.
    func capping(_ cap: (String?) -> Int64?) throws -> PlanView {
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any],
              var steps = object["steps"] as? [[String: Any]] else { return self }
        for (index, step) in steps.enumerated() where step["xdr"] == nil {
            guard let max = cap(step["stepKind"] as? String) else { continue }
            let ceiling = (step["maxFee"] as? String).flatMap { Int64($0) }
            steps[index]["maxFee"] = String(ceiling.map { min($0, max) } ?? max)
        }
        object["steps"] = steps
        return try JSONDecoder().decode(PlanView.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
