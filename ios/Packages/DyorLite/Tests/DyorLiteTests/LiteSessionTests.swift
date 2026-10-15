@testable import DyorLite
import StellarKit
import XCTest

/// `LiteSession` without access gating (docs/DESIGN-stellar-parity.md §1.1 decision 6, §7.2, §8.14), against a fake
/// server with the real `LiteAPI`, and key providers that count every prompt and every Keychain read: nothing prompts
/// to resume, renew, recover from a 401 or read; renewal goes refresh token → silent sign-in → public view; no locked
/// state exists; App Lock is asked once per run and only when it applies; a passkey setup is one ceremony; no signer
/// outlives a run or the background; Sign out makes the next switch a sign-in.
@MainActor
final class LiteSessionTests: XCTestCase {
    private var server: FakeLite!
    private var backend: TestBackend!
    private var vault: MemoryVault!
    private var defaults: UserDefaults!
    private var tally: Tally!

    override func setUp() async throws {
        server = FakeLite()
        server.serve()
        backend = TestBackend(api: server.api())
        backend.afterRun = { [server] plan in if plan.planId == "setup" { server?.update { $0.usdc = true } } }
        vault = MemoryVault()
        defaults = UserDefaults(suiteName: "lite.session.tests.\(UUID().uuidString)")
        tally = Tally()
    }

    override func tearDown() async throws {
        server.stop()
    }

    private var seedAddress: String { TestAccount.seedSigner.address }

    /// A seed account's session (its seed is on this iPhone): `appLock` is App Lock's setting.
    private func seedSession(appLock: Bool = true) -> LiteSession {
        LiteSession(env: env, stellarAddress: seedAddress, monad: nil, keys: TestAccount.seedKeys(appLock: appLock, tally: tally), setupKey: nil,
                    backend: backend, vault: vault, defaults: defaults)
    }

    /// A passkey account's session: its address known once set up on this iPhone, nil before its first ceremony.
    private func passkeySession(known: Bool = false, ceremonyFails: Error? = nil) -> LiteSession {
        LiteSession(env: env, stellarAddress: known ? TestAccount.passkeyAddress : nil, monad: nil,
                    keys: known ? TestAccount.passkeyKeys(tally: tally) : nil, setupKey: TestAccount.setupKey(tally: tally, failing: ceremonyFails),
                    backend: backend, vault: vault, defaults: defaults)
    }

    private var env: LiteEnvironment { LiteEnvironment(apiURL: server.base, pinned: .testnet, buildNumber: 23) }

    private func activate(_ address: String) { defaults.set(true, forKey: LiteSession.activatedKey(address)) }
    private func steps(_ s: LiteSession) -> [LiteSession.Step] { s.steps.map(\.step) }
    private func status(_ s: LiteSession, _ step: LiteSession.Step) -> LiteSession.StepStatus? { s.steps.first { $0.step == step }?.status }

    // MARK: - plan()

    func testPlanIsLocalNeverPromptsAndIsInstantOnceSetUp() async throws {
        let passkey = passkeySession()
        XCTAssertEqual(passkey.plan(), .setup([.signIn, .setUp]), "a passkey account before its first ceremony")
        let s = seedSession()
        XCTAssertEqual(s.plan(), .setup([.signIn, .setUp]), "not set up on this iPhone")
        activate(seedAddress)
        XCTAssertEqual(s.plan(), .instant, "set up here: instant, with no session at all")
        vault.save(server.issueSession(lifetime: -60), account: seedAddress, network: "testnet")
        XCTAssertEqual(s.plan(), .instant, "an ended session changes nothing (no 12-hour lock)")
        defaults.set(true, forKey: LiteSession.signedOutKey(seedAddress))
        XCTAssertEqual(s.plan(), .setup([.signIn]), "after Sign out of Stellar: the sign-in only")
        XCTAssertEqual(server.seen.count, 0, "plan() never reaches the network")
        XCTAssertEqual(tally.prompts, 0)
        XCTAssertEqual(tally("seedRead"), 0)
    }

    // MARK: - Seed accounts' setup

    func testASeedSetupSignsInSilentlyAndAsksAppLockOnceAtSetUp() async throws {
        server.update {
            $0.exists = false
            $0.usdc = false
        }
        let s = seedSession(appLock: true)
        await s.run()
        XCTAssertEqual(s.state, .waiting(.setUp))
        XCTAssertEqual(steps(s), [.signIn, .setUp])
        XCTAssertEqual(status(s, .signIn), .done)
        XCTAssertEqual(tally.prompts, 0, "the sign-in is silent")
        XCTAssertEqual(tally("seedRead"), 1, "one read of the seed, for the sign-in's one signature")
        XCTAssertFalse(s.holdsSigner, "nothing is held while the run waits for the tap")
        XCTAssertEqual(s.access, .session)
        // The Enable USDC step's price before the tap: its estimate and the base reserve it holds.
        XCTAssertEqual(s.setupFee?.userMax, 10_000)
        XCTAssertEqual(s.setupFee?.newReserves, 1)
        XCTAssertEqual(s.baseReserve, 5_000_000)

        await s.setUp()
        XCTAssertEqual(s.state, .ready, "\(s.steps)")
        XCTAssertEqual(s.steps.map(\.status), [.done, .done])
        XCTAssertEqual(tally("appLock"), 1, "App Lock once, at the Set Up tap")
        XCTAssertEqual(tally("seedRead"), 2, "the Enable USDC signature read the seed for itself")
        XCTAssertEqual(backend.plans, ["setup"])
        XCTAssertEqual(backend.signatures, 1)
        XCTAssertFalse(s.holdsSigner)
        XCTAssertEqual(s.home, .ready)
        XCTAssertNotNil(s.store)
        XCTAssertEqual(s.plan(), .instant)
        XCTAssertTrue(defaults.bool(forKey: LiteSession.activatedKey(seedAddress)))
        XCTAssertNotNil(vault.load(account: seedAddress, network: "testnet")?.refreshToken, "the refresh token is kept")
    }

    func testASeedSetupWithAppLockOffNeverPrompts() async throws {
        server.update {
            $0.exists = false
            $0.usdc = false
        }
        let s = seedSession(appLock: false)
        await s.run()
        await s.setUp()
        XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(tally.prompts, 0)
    }

    func testAnInviteIsAskedOnlyWhenTheServerWantsOneAndNothingIsHeldMeanwhile() async throws {
        server.update { $0.invited = false }
        let s = seedSession()
        await s.run()
        XCTAssertEqual(s.state, .waiting(.invite))
        XCTAssertEqual(steps(s), [.invite, .setUp], "the invite takes the sign-in's place")
        XCTAssertFalse(s.holdsSigner)

        await s.join(invite: " dyor-wrong ")
        XCTAssertEqual(s.state, .failed(.invite, .inviteRejected))
        await s.join(invite: "dyor-good")
        XCTAssertEqual(s.state, .ready, "already set up: the run ends")
        XCTAssertEqual(server.seen.filter { $0.path == "/v1/auth/verify" }.map { $0.json["inviteCode"] }, [nil, "DYOR-WRONG", "DYOR-GOOD"],
                       "each sign-in is a fresh signature; codes are trimmed and capitalized")
        XCTAssertEqual(tally.prompts, 0)
    }

    // MARK: - Passkey accounts' setup

    func testAPasskeySetupIsOneCeremonyFromSignInToEnable() async throws {
        server.update {
            $0.exists = false
            $0.usdc = false
        }
        let s = passkeySession()
        await s.run()
        XCTAssertEqual(s.state, .waiting(.setUp), "the Set Up tap comes first")
        XCTAssertEqual(steps(s), [.signIn, .setUp])
        XCTAssertEqual(status(s, .signIn), .pending)
        XCTAssertEqual(tally.prompts, 0, "nothing asked before the tap")
        XCTAssertNotNil(s.setupFee, "priced before the tap")

        await s.setUp(invite: nil)
        XCTAssertEqual(s.state, .ready, "\(s.steps)")
        XCTAssertEqual(tally("ceremony"), 1)
        XCTAssertEqual(tally.prompts, 1, "exactly one passkey prompt for the sign-in and Enable USDC")
        XCTAssertEqual(backend.signatures, 1, "its signer signed the Enable USDC step too")
        XCTAssertEqual(s.address, TestAccount.passkeyAddress, "the ceremony gave the address")
        XCTAssertEqual(s.methodLabel, "Passkey")
        XCTAssertFalse(s.holdsSigner, "dropped once the run ended")
        XCTAssertEqual(tally("appLock"), 0, "a passkey account never gets App Lock")
    }

    func testAPasskeyAccountAskedForAnInviteRunsANewCeremonyWithTheCode() async throws {
        server.update { $0.invited = false }
        let s = passkeySession()
        await s.run()
        await s.setUp(invite: nil)
        XCTAssertEqual(s.state, .waiting(.invite))
        XCTAssertFalse(s.holdsSigner, "the run kept nothing while it waits for the code")
        await s.join(invite: "DYOR-GOOD")
        XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(tally("ceremony"), 2, "the next tap asks for the passkey again")
    }

    func testGoingToTheBackgroundEndsAPasskeyRunAndItsSigner() async throws {
        server.update {
            $0.exists = false
            $0.usdc = false
        }
        backend.stepPause = 2
        let s = passkeySession()
        await s.run()
        let run = Task { await s.setUp(invite: nil) }
        await waitUntil { s.holdsSigner && self.backend.plans == ["setup"] }
        XCTAssertTrue(s.holdsSigner, "the run holds its signer only while it runs")
        s.appDidEnterBackground()
        XCTAssertFalse(s.holdsSigner, "no signer survives the background")
        XCTAssertEqual(s.state, .failed(.setUp, .cancelled))
        XCTAssertEqual(LiteSession.Failure.cancelled.errorDescription, tr("Not finished. Try again."))
        await run.value
        XCTAssertEqual(backend.signatures, 0, "the step couldn't sign once the signer was gone")
        XCTAssertNotEqual(s.home, .ready)
    }

    func testACeremonyForAnotherAccountIsRefused() async throws {
        let other = try StellarSigner(seed: Array(repeating: 9, count: 32))
        let s = LiteSession(env: env, stellarAddress: TestAccount.passkeyAddress, monad: nil, keys: nil,
                            setupKey: { _ in .init(keys: WatchOnlyKeyProvider(address: other.address), signer: other) },
                            backend: backend, vault: vault, defaults: defaults)
        await s.run()
        await s.setUp()
        XCTAssertEqual(s.state, .failed(.signIn, .otherAccountsKey))
        XCTAssertFalse(s.holdsSigner)
    }

    // MARK: - Launch, renewal, 401s and reads: never a prompt

    func testResumeAtLaunchIsReadyAtOnceAndNeverPrompts() async throws {
        activate(seedAddress)
        vault.save(server.issueSession(), account: seedAddress, network: "testnet")
        let s = seedSession()
        await s.resumeAtLaunch()
        XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(s.home, .ready)
        XCTAssertEqual(s.access, .session)
        XCTAssertNotNil(s.store)
        XCTAssertFalse(server.paths.contains { $0.contains("/v1/auth/") }, "a live session needs no auth call")
        XCTAssertEqual(tally.prompts, 0)
        XCTAssertEqual(tally("seedRead"), 0)
    }

    func testAnEndedSessionRenewsWithItsRefreshTokenFirst() async throws {
        activate(seedAddress)
        let saved = server.issueSession(lifetime: -3600)
        vault.save(saved, account: seedAddress, network: "testnet")
        let s = seedSession()
        await s.resumeAtLaunch()
        XCTAssertEqual(s.home, .ready, "ready from the first frame, whatever the session")
        XCTAssertEqual(s.access, .session)
        XCTAssertTrue(server.paths.contains("POST /v1/auth/refresh"))
        XCTAssertFalse(server.paths.contains("POST /v1/auth/challenge"), "the refresh token was enough")
        XCTAssertEqual(server.seen.first { $0.path == "/v1/auth/refresh" }?.json["refreshToken"], saved.refreshToken)
        XCTAssertNotEqual(vault.load(account: seedAddress, network: "testnet")?.refreshToken, saved.refreshToken, "the rotated token is kept")
        XCTAssertEqual(tally.prompts, 0)
        XCTAssertEqual(tally("seedRead"), 0)
    }

    func testRenewalGoesRefreshThenSilentSignInForASeedAccount() async throws {
        activate(seedAddress)
        var saved = server.issueSession(lifetime: -3600)
        // A refresh token the server no longer knows (revoked, or 30 days unused).
        saved = LiteSavedSession(token: saved.token, expiresAt: saved.expiresAt, refreshToken: "lrt_gone", refreshExpiresAt: saved.refreshExpiresAt)
        vault.save(saved, account: seedAddress, network: "testnet")
        let s = seedSession()
        await s.resumeAtLaunch()
        let auth = server.paths.filter { $0.contains("/v1/auth/") }
        XCTAssertEqual(auth, ["POST /v1/auth/refresh", "POST /v1/auth/challenge", "POST /v1/auth/verify"], "refresh first, then the silent sign-in")
        XCTAssertEqual(s.access, .session)
        XCTAssertEqual(tally.prompts, 0)
        XCTAssertEqual(tally("seedRead"), 1, "the sign-in's one signature")
    }

    func testRenewalEndsInThePublicViewForAPasskeyAccount() async throws {
        activate(TestAccount.passkeyAddress)
        let saved = server.issueSession(lifetime: -3600)
        vault.save(LiteSavedSession(token: saved.token, expiresAt: saved.expiresAt, refreshToken: "lrt_gone"), account: TestAccount.passkeyAddress, network: "testnet")
        let s = passkeySession(known: true)
        await s.resumeAtLaunch()
        XCTAssertEqual(server.paths.filter { $0.contains("/v1/auth/") }, ["POST /v1/auth/refresh"], "no sign-in: that would need the passkey")
        XCTAssertEqual(s.access, .publicView)
        XCTAssertTrue(s.needsSignIn)
        XCTAssertEqual(s.home, .ready, "the public view is no lock")
        XCTAssertNil(vault.load(account: TestAccount.passkeyAddress, network: "testnet"), "the dead session goes")
        XCTAssertEqual(tally.prompts, 0)

        // Its reads still fill, in the public view; DyorHQ's history says it needs a sign-in, and asks nothing.
        let store = try XCTUnwrap(s.store)
        await store.refreshAll()
        XCTAssertNotNil(store.holdings)
        XCTAssertEqual(store.holdings?.view, "public")
        XCTAssertEqual(store.account?.view, "public")
        XCTAssertEqual(store.status(.spot), .read)
        XCTAssertEqual(store.status(.activity), .needsSignIn)
        XCTAssertFalse(server.paths.contains("GET /v1/activity"), "a history read isn't even asked")
        XCTAssertTrue(server.seen.contains { $0.path == "/v1/holdings" && $0.route.contains("address=\(TestAccount.passkeyAddress)") })
        XCTAssertEqual(tally.prompts, 0)

        // Tapping "Sign in with your passkey": one prompt, then the history reads.
        try await s.signIn()
        XCTAssertEqual(s.access, .session)
        XCTAssertEqual(tally.prompts, 1)
        await store.refreshActivity()
        XCTAssertEqual(store.status(.activity), .read)
    }

    func testA401RenewsSilentlyAndTheReadGoesThrough() async throws {
        activate(seedAddress)
        let saved = server.issueSession()
        vault.save(saved, account: seedAddress, network: "testnet")
        let s = seedSession()
        await s.resumeAtLaunch()
        // The server ends the session early (a restart, a rotated secret): the next read gets a 401.
        server.update { $0.tokens[saved.token] = nil }
        server.forget()
        let store = try XCTUnwrap(s.store)
        await store.refreshHoldings()
        XCTAssertEqual(store.holdings?.view, "owner", "renewed, then read with the new session")
        XCTAssertEqual(server.paths, ["GET /v1/holdings", "POST /v1/auth/refresh", "GET /v1/holdings"])
        XCTAssertEqual(tally.prompts, 0)
        XCTAssertEqual(tally("seedRead"), 0)
    }

    func testRenewalsAtOnceShareOneRefresh() async throws {
        activate(seedAddress)
        vault.save(server.issueSession(lifetime: 5 * 60), account: seedAddress, network: "testnet")
        let s = seedSession()
        server.update { $0.slow["/v1/auth/refresh"] = 0.3 }
        await s.resumeAtLaunch()
        server.forget()
        async let a: Void = s.renew()
        async let b: Void = s.renew()
        _ = try await (a, b)
        XCTAssertEqual(server.paths.filter { $0 == "POST /v1/auth/refresh" }.count, 1)
    }

    func testTheTimerRenewsBeforeTheSessionEndsOnlyWhileTheAppIsInFront() async throws {
        activate(seedAddress)
        // Ends 10 minutes and a moment from now: not due at launch, due a moment later.
        vault.save(server.issueSession(lifetime: LiteSession.renewalLead + 1.5), account: seedAddress, network: "testnet")
        let s = seedSession()
        await s.resumeAtLaunch()
        XCTAssertFalse(server.paths.contains("POST /v1/auth/refresh"))
        await waitUntil(10) { self.server.paths.contains("POST /v1/auth/refresh") }
        XCTAssertTrue(server.paths.contains("POST /v1/auth/refresh"), "renewed 10 minutes before the end")

        vault.save(server.issueSession(lifetime: LiteSession.renewalLead + 3), account: seedAddress, network: "testnet")
        let other = seedSession()
        await other.resumeAtLaunch()
        other.appDidEnterBackground()
        server.forget()
        try await Task.sleep(for: .seconds(4))
        XCTAssertFalse(server.paths.contains("POST /v1/auth/refresh"), "no renewal in the background")
        XCTAssertEqual(tally.prompts, 0)
    }

    func testNoLockedStateIsReachable() async throws {
        activate(seedAddress)
        let s = seedSession()
        // No session at all, the server down, the app in the background and back: always ready, never locked.
        server.update { $0.offline = ["/v1/auth/challenge", "/v1/auth/verify"] }
        await s.resumeAtLaunch()
        XCTAssertEqual(s.home, .ready)
        XCTAssertEqual(s.state, .ready)
        s.appDidEnterBackground()
        s.appDidBecomeActive()
        await s.refreshHome()
        XCTAssertEqual(s.home, .ready)
        XCTAssertEqual(s.state, .ready)
        for state in [s.state] {
            switch state {
            case .idle, .running, .waiting, .ready, .unavailable, .failed: break
            }
        }
        for phase in [s.home] {
            switch phase {
            case .loading, .ready, .paused: break
            }
        }
        XCTAssertEqual(tally.prompts, 0)
    }

    // MARK: - The silent check

    func testAPausedServiceOrATooOldBuildFailsBeforeAnyPrompt() async throws {
        server.update { $0.enabled = false }
        var s = seedSession()
        await s.run()
        XCTAssertEqual(s.state, .unavailable(.paused))
        XCTAssertEqual(s.home, .paused(.paused))
        XCTAssertFalse(LiteSession.Failure.paused.canRetry)

        server.update {
            $0.enabled = true
            $0.minBuild = 24
        }
        s = seedSession()
        await s.run()
        XCTAssertEqual(s.state, .unavailable(.updateRequired))

        server.update {
            $0.minBuild = 1
            $0.sponsor = "GDIFFERENTSPONSOR"
        }
        s = seedSession()
        await s.run()
        XCTAssertEqual(s.state, .unavailable(.updateRequired))
        XCTAssertEqual(tally.prompts, 0)
        XCTAssertEqual(tally("seedRead"), 0)
    }

    func testOfflineAtTheCheckIsRetriedFromTheStart() async throws {
        server.update { $0.offline = ["/v1/config"] }
        let s = seedSession()
        await s.run()
        XCTAssertEqual(s.state, .failed(nil, .offline))
        server.update { $0.offline = [] }
        await s.retry()
        XCTAssertEqual(s.state, .ready)
    }

    func testAFailedSetupSaysNothingWasSpentAndRetries() async throws {
        server.update {
            $0.exists = false
            $0.usdc = false
        }
        backend.failure = PlanRunner.Failure.refused(step: "Enable USDC", reason: "test")
        let s = seedSession()
        await s.run()
        await s.join(invite: "x") // not waiting for an invite: ignored
        XCTAssertEqual(s.state, .waiting(.setUp))
        await s.setUp()
        XCTAssertEqual(s.state, .failed(.setUp, .setUpFailed))
        XCTAssertEqual(LiteSession.Failure.setUpFailed.errorDescription, tr("Couldn't set up your Stellar account. Nothing was spent."))
        backend.failure = nil
        await s.retry()
        XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(tally("appLock"), 2, "each Set Up is its own confirmed action")
    }

    func testTheSetupRunsAtNoMoreThanTheFeeShownBeforeTheTap() async throws {
        server.update {
            $0.exists = false
            $0.usdc = false
            // The server answers the step with a ceiling 10 times the estimate shown before the tap.
            $0.plan = FakeLite.plan(id: "setup", steps: [("s1", "trust", "Enable USDC", 100_000)])
        }
        let s = seedSession()
        await s.run()
        XCTAssertEqual(s.setupFee?.userMax, 10_000, "the estimate, before the tap")
        await s.setUp()
        XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(backend.lastFees?.maxFee("s1"), 10_000, "the step must be built within the figure the user saw")
        XCTAssertEqual(s.setupFee?.userMax, 10_000)
    }

    // MARK: - Sign out

    func testSignOutRevokesErasesAndMakesTheNextSwitchASignIn() async throws {
        activate(seedAddress)
        let saved = server.issueSession()
        vault.save(saved, account: seedAddress, network: "testnet")
        let s = seedSession()
        var signedOut: String?
        s.onSignOut = { signedOut = $0 }
        await s.resumeAtLaunch()
        await s.signOut()
        XCTAssertEqual(server.seen.last { $0.path == "/v1/auth/signout" }?.json["refreshToken"], saved.refreshToken, "the family is revoked")
        XCTAssertNil(vault.load(account: seedAddress, network: "testnet"))
        XCTAssertNil(s.store, "the figures go")
        XCTAssertEqual(signedOut, seedAddress)
        XCTAssertEqual(s.plan(), .setup([.signIn]))
        XCTAssertEqual(s.access, .publicView)
        XCTAssertNotEqual(s.home, .ready)

        // The next switch: the sign-in only, silent for a seed account; then instant again.
        await s.run()
        XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(s.plan(), .instant)
        XCTAssertEqual(tally.prompts, 0)
    }

    func testAPasskeyAccountSignedOutSignsInWithOnePromptAndSpendsNothing() async throws {
        activate(TestAccount.passkeyAddress)
        defaults.set(true, forKey: LiteSession.signedOutKey(TestAccount.passkeyAddress))
        let s = passkeySession(known: true)
        XCTAssertEqual(s.plan(), .setup([.signIn]))
        await s.run()
        XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(tally.prompts, 1)
        XCTAssertEqual(backend.plans, [], "already set up: nothing is sent")
        XCTAssertFalse(s.holdsSigner)
    }

    // MARK: - Errors

    func testFailureCopyAndRetryability() {
        XCTAssertEqual(LiteSession.failure(for: LiteAPIError.transport("x")), .offline)
        XCTAssertEqual(LiteSession.failure(for: URLError(.timedOut)), .offline)
        XCTAssertEqual(LiteSession.failure(for: KeyError.badMnemonic), .otherAccountsKey)
        XCTAssertEqual(LiteSession.failure(for: LiteAPIError.server(status: 403, code: "bad_invite", message: "refused")), .inviteRejected)
        XCTAssertEqual(LiteSession.failure(for: LiteAPIError.server(status: 400, code: "friendbot_slow", message: "Testnet is slow to create the account. Try again in a minute.")),
                       .server("Testnet is slow to create the account. Try again in a minute."))
        XCTAssertEqual(LiteSession.failure(for: NSError(domain: "com.apple.LocalAuthentication", code: -2)), .cancelled)
        XCTAssertEqual(LiteSession.setUpFailure(for: PlanRunner.Failure.timedOut(step: "Enable USDC", hash: "h")), .setUpFailed)
        XCTAssertEqual(LiteSession.setUpFailure(for: LiteAPIError.transport("x")), .offline)
        for failure in [LiteSession.Failure.paused, .updateRequired, .accessRevoked, .keyNotOnDevice] { XCTAssertFalse(failure.canRetry) }
        for failure in [LiteSession.Failure.offline, .cancelled, .otherAccountsKey, .inviteRejected, .rateLimited, .setUpFailed, .server("x")] {
            XCTAssertTrue(failure.canRetry)
        }
        XCTAssertEqual(LiteSession.Failure.needsPasskey, .server(tr("Sign in with your passkey to continue.")))
    }
}
