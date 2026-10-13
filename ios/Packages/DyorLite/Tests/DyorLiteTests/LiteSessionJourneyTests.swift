@testable import DyorLite
import StellarKit
import XCTest

/// Runs only when pointed at a Lite API on testnet (the simulator test runner takes the variables with a TEST_RUNNER_
/// prefix):
///   TEST_RUNNER_LITE_API=http://127.0.0.1:8000/lite TEST_RUNNER_LITE_INVITE=DYOR-XXXXX-XXXXX \
///     xcodebuild test -scheme DyorLite -only-testing:DyorLiteTests/LiteSessionJourneyTests …
/// The session as the app drives it, through its public API: a fresh SEP-5 key through the setup run (one unlock, an
/// invite, the account's setup on testnet), then a cold launch on a new session that restores silently. It spends a
/// testnet account's activation from the API's sponsor, like the journey test in StellarKit.
///
/// The sessions keep the Stellar session in the Keychain, as in the app. A package's tests on the simulator run without
/// an app host, where the Keychain refuses writes: there both sessions share an in-memory store of the same shape
/// instead, so the save → restore across "launches" is still what is tested.
@MainActor
final class LiteSessionJourneyTests: XCTestCase {
    func testSetupRunThenResumeOnTestnet() async throws {
        let variables = ProcessInfo.processInfo.environment
        guard let base = variables["LITE_API"].flatMap(URL.init(string:)), let invite = variables["LITE_INVITE"], !invite.isEmpty else {
            throw XCTSkip("LITE_API and LITE_INVITE not set")
        }
        let phrase = try XCTUnwrap(Mnemonic.phrase(entropy: (0..<32).map { _ in UInt8.random(in: 0...255) }))
        let keys = PhraseKeyProvider(address: try StellarDerivation.sep5(mnemonic: phrase).address, methodLabel: "Test phrase") { _ in phrase }
        let prompts = Counter()
        let unlock: @Sendable (String) async throws -> LiteSession.UnlockResult = { reason in
            await prompts.increment()
            return .init(keys: keys, signer: try await keys.signer(reason: reason))
        }
        // A build number no server minimum refuses.
        let env = LiteEnvironment(apiURL: base, pinned: .testnet, buildNumber: 1_000_000)
        defer { UserDefaults.standard.removeObject(forKey: LiteSession.activatedKey(keys.address)) }
        let keychain = Self.keychainWorks()
        let shared = MemoryVault()
        func makeSession(_ address: String?) -> LiteSession {
            if keychain { return LiteSession(env: env, stellarAddress: address, monad: nil, unlock: unlock) }
            return LiteSession(env: env, stellarAddress: address, monad: nil, keys: nil,
                               backend: LiveBackend(api: LiteAPI(baseURL: env.apiURL), pinned: env.pinned),
                               vault: shared, defaults: .standard, unlock: unlock)
        }
        if !keychain { print("LiteSessionJourneyTests: no Keychain in this test runner; the sessions share an in-memory vault") }

        // The first switch: the address isn't known until the unlock derives it.
        let session = makeSession(nil)
        XCTAssertEqual(session.plan(), .setup([.unlock, .signIn, .setUp]))
        await session.run()
        XCTAssertEqual(session.state, .waiting(.invite), "a new account is asked for its invite")
        XCTAssertEqual(session.steps.map(\.step), [.unlock, .invite, .setUp])
        await session.join(invite: invite)
        XCTAssertEqual(session.state, .waiting(.setUp), "signed in; the account isn't set up yet")
        XCTAssertNotNil(session.store)
        await session.setUp()
        XCTAssertEqual(session.state, .ready, "steps: \(session.steps)")
        XCTAssertEqual(session.steps.map(\.status), [.done, .done, .done])
        XCTAssertEqual(session.plan(), .instant)
        let afterSetup = await prompts.value
        XCTAssertEqual(afterSetup, 1, "one unlock for the whole run")

        // A cold launch: a new session for the same account, from what this iPhone saved.
        let relaunched = makeSession(keys.address)
        await relaunched.resumeAtLaunch()
        XCTAssertEqual(relaunched.state, .ready, "the saved session is restored")
        let store = try XCTUnwrap(relaunched.store)
        await store.refreshAccount()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.account?.exists, true)
        XCTAssertEqual(store.account?.balances.first { $0.asset == "USDC" }?.enabled, true)
        let afterLaunch = await prompts.value
        XCTAssertEqual(afterLaunch, 1, "never a prompt at launch")

        // Leave nothing on the device: the saved session goes with the sign-out.
        await relaunched.signOut()
        XCTAssertEqual(relaunched.state, .locked)
        XCTAssertNil(relaunched.vault.load(account: keys.address, network: "testnet"))
    }

    /// Whether this process can write to the Keychain and read it back (an app host can; a bare test runner on the
    /// simulator can't).
    private static func keychainWorks() -> Bool {
        let probe = "probe-\(UUID().uuidString)"
        defer { StellarKeychain.eraseSession(account: probe, network: "testnet") }
        guard (try? StellarKeychain.saveSession(token: "probe", expiresAt: Date().addingTimeInterval(60), account: probe, network: "testnet")) != nil else {
            return false
        }
        return StellarKeychain.session(account: probe, network: "testnet")?.token == "probe"
    }
}
