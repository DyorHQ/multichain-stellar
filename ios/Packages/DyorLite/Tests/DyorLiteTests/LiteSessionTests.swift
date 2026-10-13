@testable import DyorLite
import StellarKit
import XCTest

/// `LiteSession`'s plan and setup run against a test double of the API: what each step does to the state and the
/// checklist, which server answers map to which failures, and when the run's signer lives and goes (one unlock per run).
@MainActor
final class LiteSessionTests: XCTestCase {
    private var signer: StellarSigner!
    private var backend: FakeBackend!
    private var vault: MemoryVault!
    private var defaults: UserDefaults!
    private var prompts: Counter!

    override func setUp() async throws {
        signer = try StellarSigner(seed: Array(repeating: 7, count: 32))
        backend = FakeBackend()
        vault = MemoryVault()
        defaults = UserDefaults(suiteName: "lite.session.tests.\(UUID().uuidString)")
        prompts = Counter()
    }

    private func session(address: String?? = .none, unlock: (@Sendable (String) async throws -> LiteSession.UnlockResult)? = nil) -> LiteSession {
        let signer = self.signer!
        let prompts = self.prompts!
        let keys = TestKeys(signer: signer)
        let env = LiteEnvironment(apiURL: URL(string: "http://127.0.0.1:9/lite")!, pinned: .testnet, buildNumber: 23)
        return LiteSession(env: env, stellarAddress: address ?? signer.address, monad: nil, keys: nil, backend: backend, vault: vault,
                           defaults: defaults, unlock: unlock ?? { _ in
                               await prompts.increment()
                               return .init(keys: keys, signer: signer)
                           })
    }

    private func steps(_ session: LiteSession) -> [LiteSession.Step] { session.steps.map(\.step) }
    private func status(_ session: LiteSession, _ step: LiteSession.Step) -> LiteSession.StepStatus? { session.steps.first { $0.step == step }?.status }

    // MARK: - plan()

    func testPlanIsLocalAndFollowsTheSessionAndTheSetupCache() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var s = session(address: .some(nil))
        s.now = { now }
        XCTAssertEqual(s.plan(), .setup([.unlock, .signIn, .setUp]), "no address yet: everything")

        s = session()
        s.now = { now }
        XCTAssertEqual(s.plan(), .setup([.unlock, .signIn, .setUp]), "an address, no session, not set up")

        vault.save(token: "t", expiresAt: now.addingTimeInterval(3600), account: signer.address, network: "testnet")
        XCTAssertEqual(s.plan(), .setup([.setUp]), "signed in, not set up")

        defaults.set(true, forKey: LiteSession.activatedKey(signer.address))
        XCTAssertEqual(s.plan(), .instant, "signed in for an hour, set up")

        vault.save(token: "t", expiresAt: now.addingTimeInterval(4 * 60), account: signer.address, network: "testnet")
        XCTAssertEqual(s.plan(), .setup([.unlock, .signIn]), "under 5 minutes left: sign in again")

        vault.erase(account: signer.address, network: "testnet")
        XCTAssertEqual(s.plan(), .setup([.unlock, .signIn]), "the 12-hour session ended")

        let calls = await backend.calls
        let unlocked = await prompts.value
        XCTAssertEqual(calls, [], "plan() never reaches the network")
        XCTAssertEqual(unlocked, 0, "plan() never prompts")
    }

    // MARK: - The first switch

    func testFirstSwitchTakesOneUnlockThroughInviteAndSetup() async throws {
        await backend.queue(signIns: [.failure(Self.error(403, "not_invited")), .failure(Self.error(403, "bad_invite")), .success(Self.auth())])
        await backend.queue(accounts: [.success(Self.account(exists: false, usdc: false)), .success(Self.account(exists: true, usdc: true))])
        let s = session()

        await s.run()
        XCTAssertEqual(s.state, .waiting(.invite))
        XCTAssertEqual(steps(s), [.unlock, .invite, .setUp], "the invite takes the sign-in's place")
        XCTAssertEqual(status(s, .unlock), .done)
        XCTAssertEqual(status(s, .invite), .needsYou)
        XCTAssertTrue(s.holdsSigner)

        await s.join(invite: " dyor-abcde-fghij ")
        XCTAssertEqual(s.state, .failed(.invite, .inviteRejected))
        XCTAssertEqual(status(s, .invite), .failed(.inviteRejected))

        await s.join(invite: "DYOR-ABCDE-FGHJK")
        XCTAssertEqual(s.state, .waiting(.setUp))
        XCTAssertEqual(steps(s), [.unlock, .signIn, .setUp])
        XCTAssertEqual(status(s, .signIn), .done)
        XCTAssertEqual(status(s, .setUp), .needsYou)
        XCTAssertNotNil(s.store, "signed in: the store exists")

        await s.setUp()
        XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(s.steps.map(\.status), [.done, .done, .done])
        XCTAssertFalse(s.holdsSigner, "the run ended: the signer is gone")

        let unlocked = await prompts.value
        let invites = await backend.invites
        let activations = await backend.activations
        XCTAssertEqual(unlocked, 1, "one unlock for the whole run")
        XCTAssertEqual(invites, [nil, "DYOR-ABCDE-FGHIJ", "DYOR-ABCDE-FGHJK"], "each sign-in is a fresh signature; codes are trimmed and capitalized")
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(defaults.bool(forKey: LiteSession.activatedKey(signer.address)), "set up: cached")
        XCTAssertNotNil(vault.load(account: signer.address, network: "testnet"), "the session is saved")
        XCTAssertEqual(s.plan(), .instant, "the next switch is instant")
    }

    func testAnAccountAlreadySetUpCompletesWithoutAsking() async throws {
        await backend.queue(accounts: [.success(Self.account(exists: true, usdc: true))])
        let s = session()
        await s.run()
        XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(status(s, .setUp), .done)
        let activations = await backend.activations
        XCTAssertEqual(activations, 0)
    }

    func testASavedSessionNeedsNoUnlockToFinishTheSetupCheck() async throws {
        vault.save(token: "t", expiresAt: Date().addingTimeInterval(3600), account: signer.address, network: "testnet")
        await backend.queue(accounts: [.success(Self.account(exists: true, usdc: true))])
        let s = session()
        XCTAssertEqual(s.plan(), .setup([.setUp]))
        await s.run()
        XCTAssertEqual(s.state, .ready)
        XCTAssertFalse(s.steps.contains { $0.step == .unlock }, "an unlock the run never needed isn't listed")
        let unlocked = await prompts.value
        let restored = await backend.restored
        XCTAssertEqual(unlocked, 0)
        XCTAssertEqual(restored, ["t"])
    }

    // MARK: - The silent check

    func testAPausedServiceFailsBeforeAnyPrompt() async throws {
        await backend.queue(configs: [.success(Self.config(enabled: false))])
        let s = session()
        await s.run()
        XCTAssertEqual(s.state, .unavailable(.paused))
        XCTAssertEqual(s.home, .paused(.paused), "Stellar Home shows the paused card")
        let unlocked = await prompts.value
        XCTAssertEqual(unlocked, 0)
        XCTAssertFalse(LiteSession.Failure.paused.canRetry)
    }

    func testABuildTooOldOrAnotherSponsorNeedsAnUpdate() async throws {
        await backend.queue(configs: [.success(Self.config(minBuild: 24))])
        var s = session()
        await s.run()
        XCTAssertEqual(s.state, .unavailable(.updateRequired))

        await backend.queue(configs: [.success(Self.config(sponsor: "GDIFFERENTSPONSOR"))])
        s = session()
        await s.run()
        XCTAssertEqual(s.state, .unavailable(.updateRequired))
        let unlocked = await prompts.value
        XCTAssertEqual(unlocked, 0)
    }

    func testOfflineAtTheCheckIsRetriedFromTheStart() async throws {
        await backend.queue(configs: [.failure(LiteAPIError.transport("offline")), .success(Self.config())])
        await backend.queue(accounts: [.success(Self.account(exists: true, usdc: true))])
        let s = session()
        await s.run()
        XCTAssertEqual(s.state, .failed(nil, .offline))
        let before = await prompts.value
        XCTAssertEqual(before, 0)
        await s.retry()
        XCTAssertEqual(s.state, .ready)
    }

    // MARK: - Failures and retries

    func testOfflineAtSignInRetriesWithTheSameUnlock() async throws {
        await backend.queue(signIns: [.failure(LiteAPIError.transport("timed out")), .success(Self.auth())])
        await backend.queue(accounts: [.success(Self.account(exists: true, usdc: true))])
        let s = session()
        await s.run()
        XCTAssertEqual(s.state, .failed(.signIn, .offline))
        XCTAssertEqual(status(s, .signIn), .failed(.offline))
        XCTAssertTrue(s.holdsSigner, "a failure retrying can help keeps the run's signer")
        await s.retry()
        XCTAssertEqual(s.state, .ready)
        let unlocked = await prompts.value
        XCTAssertEqual(unlocked, 1)
    }

    func testServerRefusalsMapToTheirFailures() async throws {
        await backend.queue(signIns: [.failure(Self.error(403, "access_revoked"))])
        var s = session()
        await s.run()
        XCTAssertEqual(s.state, .failed(.signIn, .accessRevoked))
        XCTAssertFalse(s.holdsSigner, "retrying can't help: the signer goes at once")

        await backend.queue(signIns: [.failure(Self.error(429, "rate_limited"))])
        s = session()
        await s.run()
        XCTAssertEqual(s.state, .failed(.signIn, .rateLimited))

        await backend.queue(signIns: [.failure(Self.error(401, "unauthorized", "That sign-in expired or was already used. Try again."))])
        s = session()
        await s.run()
        XCTAssertEqual(s.state, .failed(.signIn, .server("That sign-in expired or was already used. Try again.")))
    }

    func testUnlockFailures() async throws {
        let cancelled = NSError(domain: "com.apple.LocalAuthentication", code: -2)
        var s = session(unlock: { _ in throw cancelled })
        await s.run()
        XCTAssertEqual(s.state, .failed(.unlock, .cancelled))

        let passkey = NSError(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1001)
        s = session(unlock: { _ in throw passkey })
        await s.run()
        XCTAssertEqual(s.state, .failed(.unlock, .cancelled))

        s = session(unlock: { _ in throw KeyError.badSeed })
        await s.run()
        XCTAssertEqual(s.state, .failed(.unlock, .keyNotOnDevice))

        s = session(unlock: { _ in throw LiteSession.Failure.keyNotOnDevice })
        await s.run()
        XCTAssertEqual(s.state, .failed(.unlock, .keyNotOnDevice), "the host may throw a failure as it is")

        // Another account's key: the unlock answers for an address that isn't this account's.
        let other = try StellarSigner(seed: Array(repeating: 9, count: 32))
        s = session(unlock: { _ in .init(keys: TestKeys(signer: other), signer: other) })
        await s.run()
        XCTAssertEqual(s.state, .failed(.unlock, .otherAccountsKey))
        XCTAssertNil(s.store)
    }

    func testAFailedSetupSaysNothingWasSpentAndRetries() async throws {
        await backend.queue(accounts: [.success(Self.account(exists: false, usdc: false)), .success(Self.account(exists: true, usdc: true))])
        await backend.queue(activations: [.failure(PlanRunner.Failure.refused(step: "Enable USDC", reason: "test")), .success(())])
        let s = session()
        await s.run()
        await s.join(invite: "x") // not waiting for an invite: ignored
        XCTAssertEqual(s.state, .waiting(.setUp))
        await s.setUp()
        XCTAssertEqual(s.state, .failed(.setUp, .setUpFailed))
        XCTAssertEqual(LiteSession.Failure.setUpFailed.errorDescription, tr("Couldn't set up your Stellar account. Nothing was spent."))
        await s.retry()
        XCTAssertEqual(s.state, .ready)
        let unlocked = await prompts.value
        XCTAssertEqual(unlocked, 1)
    }

    // MARK: - The signer's life

    func testCancelDropsTheKeyAndKeepsWhatFinished() async throws {
        await backend.queue(signIns: [.failure(Self.error(403, "not_invited")), .failure(Self.error(403, "not_invited")), .success(Self.auth())])
        await backend.queue(accounts: [.success(Self.account(exists: true, usdc: true))])
        let s = session()
        await s.run()
        XCTAssertEqual(s.state, .waiting(.invite))
        s.cancel()
        XCTAssertEqual(s.state, .idle)
        XCTAssertFalse(s.holdsSigner)

        await s.run()
        XCTAssertEqual(s.state, .waiting(.invite), "the next attempt asks for the code again")
        await s.join(invite: "DYOR-ABCDE-FGHJK")
        XCTAssertEqual(s.state, .ready)
        let unlocked = await prompts.value
        XCTAssertEqual(unlocked, 2, "a cancelled run's key is gone: the next one unlocks again")
    }

    func testTheSignerGoesAfterIdlingAndTheNextStepUnlocksAgain() async throws {
        await backend.queue(accounts: [.success(Self.account(exists: false, usdc: false)), .success(Self.account(exists: true, usdc: true))])
        let s = session()
        s.idleTimeout = .milliseconds(50)
        await s.run()
        XCTAssertEqual(s.state, .waiting(.setUp))
        XCTAssertTrue(s.holdsSigner)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(s.holdsSigner, "dropped after the idle timeout")
        XCTAssertEqual(status(s, .unlock), .pending, "Unlock again to continue.")
        XCTAssertEqual(s.state, .waiting(.setUp), "still waiting for the tap")

        await s.setUp()
        XCTAssertEqual(s.state, .ready)
        let unlocked = await prompts.value
        XCTAssertEqual(unlocked, 2)
    }

    func testGoingToTheBackgroundDropsTheSigner() async throws {
        await backend.queue(signIns: [.failure(Self.error(403, "not_invited")), .success(Self.auth())])
        await backend.queue(accounts: [.success(Self.account(exists: true, usdc: true))])
        let s = session()
        await s.run()
        XCTAssertTrue(s.holdsSigner)
        s.appDidEnterBackground()
        XCTAssertFalse(s.holdsSigner)
        XCTAssertEqual(status(s, .unlock), .pending)
        await s.join(invite: "DYOR-ABCDE-FGHJK")
        XCTAssertEqual(s.state, .ready)
        let unlocked = await prompts.value
        XCTAssertEqual(unlocked, 2, "Join unlocks first")
    }

    // MARK: - Launch, sign-out, a lost session

    func testResumeAtLaunchNeverPrompts() async throws {
        defaults.set(true, forKey: LiteSession.activatedKey(signer.address))
        vault.save(token: "saved", expiresAt: Date().addingTimeInterval(3600), account: signer.address, network: "testnet")
        var s = session()
        await s.resumeAtLaunch()
        XCTAssertEqual(s.state, .ready)
        XCTAssertNotNil(s.store)
        let restored = await backend.restored
        XCTAssertEqual(restored, ["saved"])

        vault.save(token: "old", expiresAt: Date().addingTimeInterval(30), account: signer.address, network: "testnet")
        s = session()
        await s.resumeAtLaunch()
        XCTAssertEqual(s.state, .locked, "a session ending within the minute isn't restored")
        XCTAssertEqual(s.home, .locked)

        await backend.queue(configs: [.success(Self.config(enabled: false))])
        vault.save(token: "saved", expiresAt: Date().addingTimeInterval(3600), account: signer.address, network: "testnet")
        s = session()
        await s.resumeAtLaunch()
        XCTAssertEqual(s.state, .unavailable(.paused))

        let unlocked = await prompts.value
        XCTAssertEqual(unlocked, 0)
    }

    func testSignOutEndsTheSessionAndKeepsTheSetup() async throws {
        await backend.queue(accounts: [.success(Self.account(exists: true, usdc: true))])
        let s = session()
        await s.run()
        XCTAssertEqual(s.state, .ready)
        await s.signOut()
        XCTAssertEqual(s.state, .locked)
        XCTAssertNil(s.store)
        XCTAssertNil(vault.load(account: signer.address, network: "testnet"))
        XCTAssertEqual(s.plan(), .setup([.unlock, .signIn]), "still set up: unlock and sign in again")
    }

    func testALostSessionLocksHome() async throws {
        await backend.queue(accounts: [.success(Self.account(exists: true, usdc: true))])
        let s = session()
        await s.run()
        s.store?.report(LiteAPIError.server(status: 401, code: "unauthorized", message: "Your session expired. Sign in again."))
        XCTAssertEqual(s.state, .locked)
        XCTAssertEqual(s.home, .locked)
        XCTAssertNotNil(s.store, "the last figures stay in memory")

        s.store?.report(LiteAPIError.server(status: 403, code: "access_revoked", message: "Access to Stellar was turned off for this account."))
        XCTAssertEqual(s.state, .locked, "access is judged at the next sign-in once locked")
    }

    func testFailureCopyAndRetryability() {
        XCTAssertEqual(LiteSession.failure(for: LiteAPIError.transport("x")), .offline)
        XCTAssertEqual(LiteSession.failure(for: URLError(.timedOut)), .offline)
        XCTAssertEqual(LiteSession.failure(for: KeyError.badMnemonic), .otherAccountsKey)
        XCTAssertEqual(LiteSession.failure(for: Self.error(403, "bad_invite")), .inviteRejected)
        XCTAssertEqual(LiteSession.failure(for: Self.error(400, "friendbot_slow", "Testnet is slow to create the account. Try again in a minute.")),
                       .server("Testnet is slow to create the account. Try again in a minute."))
        XCTAssertEqual(LiteSession.setUpFailure(for: PlanRunner.Failure.timedOut(step: "Enable USDC", hash: "h")), .setUpFailed)
        XCTAssertEqual(LiteSession.setUpFailure(for: LiteAPIError.transport("x")), .offline)
        for failure in [LiteSession.Failure.paused, .updateRequired, .accessRevoked, .keyNotOnDevice] { XCTAssertFalse(failure.canRetry) }
        for failure in [LiteSession.Failure.offline, .cancelled, .otherAccountsKey, .inviteRejected, .rateLimited, .setUpFailed, .server("x")] {
            XCTAssertTrue(failure.canRetry)
        }
    }

    // MARK: - Fixtures

    nonisolated static func error(_ status: Int, _ code: String, _ message: String = "refused") -> LiteAPIError {
        .server(status: status, code: code, message: message)
    }

    nonisolated static func config(enabled: Bool = true, minBuild: Int = 1, sponsor: String = PinnedContracts.testnet.sponsor) -> LiteConfig {
        let json = """
        {"network":"testnet","passphrase":"Test SDF Network ; September 2015","rpcUrl":"http://127.0.0.1:9/rpc",
         "horizonUrl":"http://127.0.0.1:9/horizon","activation":"friendbot","sponsor":"\(sponsor)","assets":[],
         "contracts":{"launchpad":null,"moments":null,"soroswapRouter":"C","blendPools":[]},"allowlist":{},"anchors":[],
         "bridge":{"routes":[],"monad":null},"flags":{"enabled":\(enabled)},"minBuild":\(minBuild)}
        """
        return try! JSONDecoder().decode(LiteConfig.self, from: Data(json.utf8))
    }

    nonisolated static func account(exists: Bool, usdc: Bool) -> AccountView {
        let json = """
        {"address":"G","exists":\(exists),"network":"testnet","activation":"friendbot","sponsor":"G","reserves":null,
         "balances":[{"asset":"USDC","code":"USDC","name":"USD Coin","contract":"C","classic":"USDC:G","decimals":7,
                      "balance":"0","enabled":\(usdc)}]}
        """
        return try! JSONDecoder().decode(AccountView.self, from: Data(json.utf8))
    }

    nonisolated static func auth(hours: Double = 12) -> AuthResult {
        let expires = ISO8601DateFormatter.liteUI.string(from: Date().addingTimeInterval(hours * 3600))
        let json = #"{"token":"jwt","expiresAt":"\#(expires)","tester":{"address":"G","label":null}}"#
        return try! JSONDecoder().decode(AuthResult.self, from: Data(json.utf8))
    }
}

// MARK: - Test doubles

/// The API's answers, queued per call; the last one repeats. As the live backend does, a sign-in or a restore hands
/// its token to the API the store reads through (here at a closed port: its reads fail as offline, which changes
/// nothing in the session).
actor FakeBackend: LiteBackend {
    nonisolated let api = LiteAPI(baseURL: URL(string: "http://127.0.0.1:9/lite")!)
    private var configs: [Result<LiteConfig, Error>] = [.success(LiteSessionTests.config())]
    private var signIns: [Result<AuthResult, Error>] = [.success(LiteSessionTests.auth())]
    private var accounts: [Result<AccountView, Error>] = [.success(LiteSessionTests.account(exists: true, usdc: true))]
    private var activationResults: [Result<Void, Error>] = [.success(())]
    private(set) var calls: [String] = []
    private(set) var invites: [String?] = []
    private(set) var restored: [String] = []
    private(set) var activations = 0

    func queue(configs: [Result<LiteConfig, Error>]) { self.configs = configs }
    func queue(signIns: [Result<AuthResult, Error>]) { self.signIns = signIns }
    func queue(accounts: [Result<AccountView, Error>]) { self.accounts = accounts }
    func queue(activations: [Result<Void, Error>]) { activationResults = activations }

    private func next<T>(_ list: inout [Result<T, Error>]) throws -> T {
        let result = list.count > 1 ? list.removeFirst() : list[0]
        return try result.get()
    }

    func config() async throws -> LiteConfig {
        calls.append("config")
        return try next(&configs)
    }

    func restore(token: String, expiresAt: Date) async {
        restored.append(token)
        await api.restore(token: token, expiresAt: expiresAt)
    }

    func signIn(signer: StellarSigner, invite: String?) async throws -> AuthResult {
        calls.append("signIn")
        invites.append(invite)
        let result = try next(&signIns)
        await api.restore(token: result.token, expiresAt: Date().addingTimeInterval(3600))
        return result
    }

    func account() async throws -> AccountView {
        calls.append("account")
        return try next(&accounts)
    }

    func activate(signer: StellarSigner, config: LiteConfig) async throws {
        calls.append("activate")
        activations += 1
        try next(&activationResults)
    }

    func signOut() async { calls.append("signOut") }
}

final class MemoryVault: LiteSessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (token: String, expiresAt: Date)] = [:]

    func load(account: String, network: String) -> (token: String, expiresAt: Date)? {
        lock.withLock { items["\(network).\(account)"] }
    }

    func save(token: String, expiresAt: Date, account: String, network: String) {
        lock.withLock { items["\(network).\(account)"] = (token, expiresAt) }
    }

    func erase(account: String, network: String) {
        lock.withLock { _ = items.removeValue(forKey: "\(network).\(account)") }
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

struct TestKeys: LiteKeyProvider {
    let signer: StellarSigner
    var address: String { signer.address }
    let canSign = true
    let methodLabel = "Test"
    let canExportSecret = false
    func signer(reason: String) async throws -> StellarSigner { signer }
}
