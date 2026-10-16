@testable import DyorLite
import StellarKit
import XCTest

/// The session against the real thing.
///
/// The Keychain's session item, on the simulator: where the session and its refresh token live between launches. Never
/// against the macOS login keychain (`swift test` on a Mac skips it), and only where the test runner has a Keychain: a
/// package's own runner on the simulator has none (OSStatus -34018, no entitlements), a runner hosted in an app has.
///
/// The journey runs only when pointed at a Lite API on testnet (the simulator test runner takes the variables with a
/// TEST_RUNNER_ prefix):
///   TEST_RUNNER_LITE_API=http://127.0.0.1:8000/lite xcodebuild test -scheme DyorLite -only-testing:DyorLiteTests/LiteSessionJourneyTests …
/// A fresh seed account through the setup run as the app drives it (a silent sign-in, no invite on testnet, the Set Up
/// tap with App Lock on: one prompt), then a cold launch on a new session that is ready at once with no prompt. It spends
/// a testnet account's activation (Friendbot) and a trustline's fee from that account's own test XLM.
@MainActor
final class LiteSessionJourneyTests: XCTestCase {
    func testTheKeychainKeepsTheRefreshTokenWithTheSession() throws {
        #if os(macOS)
        throw XCTSkip("never against the macOS login keychain")
        #else
        if let problem = Self.keychainProblem() {
            throw XCTSkip("this test runner has no Keychain (\(problem)): a package's tests run without an app host and its entitlements")
        }
        let account = "GJOURNEY\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        defer { StellarKeychain.erase(account: account) }
        let expiresAt = Date(timeIntervalSince1970: 1_791_970_860)
        let refreshExpiresAt = Date(timeIntervalSince1970: 1_794_562_860)

        try StellarKeychain.saveSession(token: "access", expiresAt: expiresAt, refreshToken: "lrt_first", refreshExpiresAt: refreshExpiresAt,
                                        account: account, network: "testnet")
        XCTAssertEqual(StellarKeychain.session(account: account, network: "testnet")?.token, "access")
        XCTAssertEqual(StellarKeychain.session(account: account, network: "testnet")?.expiresAt, expiresAt)
        XCTAssertEqual(StellarKeychain.refreshToken(account: account, network: "testnet")?.token, "lrt_first")
        XCTAssertEqual(StellarKeychain.refreshToken(account: account, network: "testnet")?.expiresAt, refreshExpiresAt)
        XCTAssertNil(StellarKeychain.session(account: account, network: "mainnet"), "per network")

        // A rotation replaces the item whole.
        try StellarKeychain.saveSession(token: "access2", expiresAt: expiresAt, refreshToken: "lrt_second", account: account, network: "testnet")
        XCTAssertEqual(StellarKeychain.refreshToken(account: account, network: "testnet")?.token, "lrt_second")
        XCTAssertNil(StellarKeychain.refreshToken(account: account, network: "testnet")?.expiresAt, "a refresh token without its expiry is still kept")

        // An item as builds before refresh tokens saved it: the session loads, and there is no refresh token.
        try StellarKeychain.saveSession(token: "older", expiresAt: expiresAt, account: account, network: "testnet")
        XCTAssertEqual(StellarKeychain.session(account: account, network: "testnet")?.token, "older")
        XCTAssertNil(StellarKeychain.refreshToken(account: account, network: "testnet"))

        // The vault the session uses reads and writes the same item.
        let vault = KeychainSessionVault()
        let saved = LiteSavedSession(token: "vaulted", expiresAt: expiresAt, refreshToken: "lrt_vault", refreshExpiresAt: refreshExpiresAt)
        vault.save(saved, account: account, network: "testnet")
        XCTAssertEqual(vault.load(account: account, network: "testnet"), saved)

        // Sign out of Stellar: the session goes, refresh token included; the seed stays.
        try StellarKeychain.saveSeed(TestAccount.seed, account: account, network: "testnet")
        StellarKeychain.eraseSession(account: account, network: "testnet")
        XCTAssertNil(StellarKeychain.session(account: account, network: "testnet"))
        XCTAssertNil(StellarKeychain.refreshToken(account: account, network: "testnet"))
        XCTAssertNotNil(StellarKeychain.seed(account: account, network: "testnet"))

        // Sign-out of the app and erase: everything.
        try StellarKeychain.saveSession(token: "again", expiresAt: expiresAt, refreshToken: "lrt_again", account: account, network: "mainnet")
        StellarKeychain.erase(account: account)
        XCTAssertNil(StellarKeychain.session(account: account, network: "mainnet"))
        XCTAssertNil(StellarKeychain.refreshToken(account: account, network: "mainnet"))
        XCTAssertNil(StellarKeychain.seed(account: account, network: "testnet"))
        #endif
    }

    func testSetupRunThenResumeOnTestnet() async throws {
        let variables = ProcessInfo.processInfo.environment
        guard let base = variables["LITE_API"].flatMap(URL.init(string:)) else { throw XCTSkip("LITE_API not set") }
        let seed = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let address = try StellarSigner(seed: seed).address
        let tally = Tally()
        let keys = StoredSeedKeyProvider(address: address, methodLabel: "Test", network: "testnet", appLock: { true },
                                         seed: { tally.add("seedRead"); return seed }, authenticate: { _ in tally.add("appLock") })
        // A build number no server minimum refuses.
        let env = LiteEnvironment(apiURL: base, pinned: .testnet, buildNumber: 1_000_000)
        defer {
            UserDefaults.standard.removeObject(forKey: LiteSession.activatedKey(address))
            UserDefaults.standard.removeObject(forKey: LiteSession.signedOutKey(address))
        }
        // Never the macOS login keychain: on a Mac, as in a runner without a Keychain, the sessions share a vault in memory.
        #if os(macOS)
        let keychain = false
        #else
        let keychain = Self.keychainProblem() == nil
        #endif
        let shared = MemoryVault()
        func makeSession() -> LiteSession {
            if keychain { return LiteSession(env: env, stellarAddress: address, monad: nil, keys: keys) }
            let api = LiteAPI(baseURL: env.apiURL, network: "testnet")
            return LiteSession(env: env, stellarAddress: address, monad: nil, keys: keys, setupKey: nil,
                               backend: LiveBackend(api: api, pinned: env.pinned), vault: shared, defaults: .standard)
        }
        if !keychain { print("LiteSessionJourneyTests: no Keychain in this test runner; the sessions share an in-memory vault") }

        let session = makeSession()
        XCTAssertEqual(session.plan(), .setup([.signIn, .setUp]))
        await session.run()
        XCTAssertEqual(session.state, .waiting(.setUp), "signed in silently; the account isn't set up yet")
        XCTAssertEqual(tally.prompts, 0)
        XCTAssertNotNil(session.setupFee, "the Enable USDC step is priced before the tap")
        await session.setUp()
        XCTAssertEqual(session.state, .ready, "steps: \(session.steps)")
        XCTAssertEqual(session.plan(), .instant)
        XCTAssertEqual(tally("appLock"), 1, "App Lock once, at the Set Up tap")

        // A cold launch: a new session for the same account, from what this iPhone saved; ready at once.
        let relaunched = makeSession()
        await relaunched.resumeAtLaunch()
        XCTAssertEqual(relaunched.state, .ready)
        let store = try XCTUnwrap(relaunched.store)
        await store.refreshAccount()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.account?.exists, true)
        XCTAssertEqual(store.account?.balances.first { $0.asset == "USDC" }?.enabled, true)
        XCTAssertEqual(tally.prompts, 1, "never a prompt at launch")

        // Leave nothing on the device: the saved session goes with the sign-out.
        await relaunched.signOut()
        XCTAssertEqual(relaunched.plan(), .setup([.signIn]))
        XCTAssertNil(relaunched.vault.load(account: address, network: "testnet"))
    }

    /// Why this process can't write to the Keychain and read it back, or nil when it can (an app host can; a bare test
    /// runner on the simulator may not).
    private static func keychainProblem() -> String? {
        let probe = "probe-\(UUID().uuidString)"
        defer { StellarKeychain.eraseSession(account: probe, network: "testnet") }
        do {
            try StellarKeychain.saveSession(token: "probe", expiresAt: Date().addingTimeInterval(60), account: probe, network: "testnet")
        } catch {
            return "OSStatus \((error as NSError).code)"
        }
        return StellarKeychain.session(account: probe, network: "testnet")?.token == "probe" ? nil : "the item didn't read back"
    }
}
