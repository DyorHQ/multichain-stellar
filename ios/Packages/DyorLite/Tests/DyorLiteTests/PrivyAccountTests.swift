@testable import DyorLite
import StellarKit
import XCTest

/// A Privy account's Stellar session (Apple, Google, an email code, a Privy passkey: DyorHQ/internal
/// ios-app/stellar-v2/privy-stellar-wallets.md), against the fake server: its first run finds its wallet through the host
/// (`resolveKeys`, which talks to Privy itself), with no prompt, then goes as a seed account's: a silent sign-in, App Lock
/// once at Set Up. Where the server doesn't let Privy accounts in nothing is asked; a signature that doesn't verify is
/// never sent; Privy's own refusals and a wallet that isn't only the user's are said in the app's words.
@MainActor
final class PrivyAccountTests: XCTestCase {
    private var server: FakeLite!
    private var backend: TestBackend!
    private var vault: MemoryVault!
    private var defaults: UserDefaults!
    private var suite = ""
    private var tally: Tally!

    override func setUp() async throws {
        server = FakeLite()
        server.serve()
        backend = TestBackend(api: server.api())
        backend.afterRun = { [server] plan in if plan.planId == "setup" { server?.update { $0.usdc = true } } }
        vault = MemoryVault()
        suite = "lite.privy.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        tally = Tally()
        server.update {
            $0.exists = false
            $0.usdc = false
        }
    }

    override func tearDown() async throws {
        server.stop()
        defaults.removePersistentDomain(forName: suite)
    }

    private static let walletKey = try! StellarSigner(seed: [UInt8](repeating: 21, count: 32))
    private var walletAddress: String { Self.walletKey.address }
    private var env: LiteEnvironment { LiteEnvironment(apiURL: server.base, pinned: .testnet, buildNumber: 23) }

    /// The account's Privy wallet as the signer meets it: Privy's signatures, counted, made by `key` (the wallet's own,
    /// unless a test hands another).
    private func provider(key: StellarSigner = walletKey) -> RemoteKeyProvider {
        RemoteKeyProvider(signer: CountingSigner(address: walletAddress, key: key, tally: tally), methodLabel: "Google") { [tally] _ in
            tally!.add("appLock")
        }
    }

    /// A Privy account's session before its first switch: no address, no provider, the host's lookup.
    private func session(resolve: @escaping @Sendable () async throws -> LiteKeyProvider) -> LiteSession {
        LiteSession(env: env, stellarAddress: nil, monad: nil, keys: nil, setupKey: nil, resolveKeys: resolve,
                    backend: backend, vault: vault, defaults: defaults)
    }

    private func status(_ s: LiteSession, _ step: LiteSession.Step) -> LiteSession.StepStatus? { s.steps.first { $0.step == step }?.status }

    func testTheFirstSwitchFindsTheWalletSignsInSilentlyAndAsksAppLockOnceAtSetUp() async throws {
        let wallet = provider()
        let s = session { [tally] in
            tally!.add("resolve")
            return wallet
        }
        XCTAssertEqual(s.plan(), .setup([.signIn, .setUp]))
        await s.run()
        XCTAssertEqual(s.state, .waiting(.setUp), "\(s.steps)")
        XCTAssertEqual(status(s, .signIn), .done)
        XCTAssertEqual(tally("resolve"), 1)
        XCTAssertEqual(s.address, walletAddress)
        XCTAssertEqual(tally("privySign"), 1, "one signature: the sign-in challenge")
        XCTAssertEqual(tally.prompts, 0, "finding the wallet and signing in ask nothing")
        XCTAssertEqual(s.access, .session)
        XCTAssertEqual(server.paths.filter { $0.contains("/v1/auth/") }, ["POST /v1/auth/challenge", "POST /v1/auth/verify"])

        await s.setUp()
        XCTAssertEqual(s.state, .ready, "\(s.steps)")
        XCTAssertEqual(tally("appLock"), 1, "App Lock once, at the Set Up tap")
        XCTAssertEqual(tally("resolve"), 1, "the wallet is found once")
        XCTAssertEqual(backend.plans, ["setup"])
        XCTAssertEqual(backend.signatures, 1)
        XCTAssertEqual(s.methodLabel, "Google")
        XCTAssertFalse(s.canExportSecret, "Privy keeps the key")
    }

    func testWithoutPrivyWalletsOnTheServerNothingIsAskedOrSigned() async throws {
        server.update { $0.privyWallets = false }
        let s = session { [tally] in
            tally!.add("resolve")
            throw LiteSession.Failure.keyNotOnDevice
        }
        await s.run()
        XCTAssertEqual(s.state, .failed(.signIn, LiteSession.privyWalletsUnavailable))
        XCTAssertEqual(tally("resolve"), 0)
        XCTAssertTrue(server.paths.filter { $0.contains("/v1/auth/") }.isEmpty)
        XCTAssertNil(s.address)
    }

    func testAFailedLookupFailsTheSignInStepInTheAppsWordsAndTryAgainLooksAgain() async throws {
        let wallet = provider()
        let attempts = Setting(false)
        let s = session { [tally] in
            tally!.add("resolve")
            guard attempts.value else {
                attempts.value = true
                throw PrivyAPIError.unavailable(status: 503)
            }
            return wallet
        }
        await s.run()
        XCTAssertEqual(s.state, .failed(.signIn, .server(tr("Stellar isn't available for this sign-in right now. Try again later."))))
        await s.retry()
        XCTAssertEqual(s.state, .waiting(.setUp), "\(s.steps)")
        XCTAssertEqual(tally("resolve"), 2)
    }

    func testAWalletThatIsntOnlyTheUsersFailsTheSignInInTheAppsWords() async throws {
        let s = session { throw PrivyWalletCheck.Failure.notOnlyTheUsers }
        await s.run()
        XCTAssertEqual(s.state, .failed(.signIn, .server(tr("Privy didn't confirm this Stellar wallet as yours, so DyorHQ won't use it. Nothing was signed."))))
        XCTAssertNil(s.address)
        let stale = session { throw PrivyWalletCheck.Failure.listNotFresh }
        await stale.run()
        XCTAssertEqual(stale.state, .failed(.signIn, .server(tr("Stellar isn't available for this sign-in right now. Try again later."))))
        let offline = session { throw PrivyAPIError.transport("offline") }
        await offline.run()
        XCTAssertEqual(offline.state, .failed(.signIn, .offline))
        let expired = session { throw PrivyAPIError.refused(status: 401, code: nil) }
        await expired.run()
        XCTAssertEqual(expired.state, .failed(.signIn, .server(tr("Sign in to DyorHQ again to use Stellar."))))
    }

    func testAWalletForAnotherAddressThanTheOneKeptIsRefused() async throws {
        let s = LiteSession(env: env, stellarAddress: TestAccount.seedSigner.address, monad: nil, keys: nil, setupKey: nil,
                            resolveKeys: { [wallet = provider()] in wallet }, backend: backend, vault: vault, defaults: defaults)
        await s.run()
        XCTAssertEqual(s.state, .failed(.signIn, .otherAccountsKey))
        XCTAssertEqual(tally("privySign"), 0)
    }

    func testASignInSignatureThatDoesntVerifyIsNeverSent() async throws {
        let stranger = try StellarSigner(seed: [UInt8](repeating: 22, count: 32))
        let wallet = provider(key: stranger)
        let s = session { wallet }
        await s.run()
        XCTAssertEqual(s.state, .failed(.signIn, .server(tr("Couldn't sign with your Privy wallet. Nothing was sent."))))
        XCTAssertEqual(server.paths.filter { $0.contains("/v1/auth/") }, ["POST /v1/auth/challenge"], "no verify with a bad signature")
    }

    func testARunsSignerSignsNothingOnceTheRunEnded() async throws {
        let wallet = provider()
        let run = try await wallet.beginSigning(reason: "Swap")
        XCTAssertEqual(tally("appLock"), 1)
        let signer = try await run.signer(reason: "Swap")
        _ = try await signer.signHash([UInt8](repeating: 1, count: 32))
        run.end()
        do {
            _ = try await signer.signHash([UInt8](repeating: 2, count: 32))
            XCTFail("signed after the run ended")
        } catch {
            XCTAssertEqual(error as? LiteSession.Failure, .cancelled)
        }
        do {
            _ = try await wallet.revealSecret(reason: "Show")
            XCTFail("a Privy wallet has no secret here")
        } catch {}
        XCTAssertEqual(tally("privySign"), 1)
    }
}

/// A key held elsewhere, as `PrivyStellarSigner` behaves for the session: each signature counted ("privySign"), made by
/// `key`, which may not be the account's.
private struct CountingSigner: StellarHashSigner {
    let address: String
    let key: StellarSigner
    let tally: Tally

    func signHash(_ hash: [UInt8]) async throws -> [UInt8] {
        tally.add("privySign")
        return try key.sign(hash)
    }
}
