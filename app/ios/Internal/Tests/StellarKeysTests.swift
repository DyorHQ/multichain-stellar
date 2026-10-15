// How the app's Stellar key providers ask for the device owner (docs/DESIGN-stellar-parity.md §1.1 decision 6, §5.8, §7.2,
// §8.7): never to sign the sign-in, once per confirmed action and only while App Lock applies, always to show the secret
// key, and never App Lock for a passkey account.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import XCTest

@MainActor
final class StellarKeysTests: XCTestCase {
    /// What the providers asked for, counted.
    @MainActor
    final class Asked {
        /// The owner's prompts (Face ID or the passcode).
        var prompts = 0
        /// Whether a passcode is set, asked.
        var passcodeChecks = 0
        /// App Lock's setting, read.
        var appLockReads = 0
        /// Passkey ceremonies.
        var ceremonies = 0
    }

    private let seed = [UInt8](repeating: 3, count: 32)
    private var address: String { try! StellarSigner(seed: seed).address }

    private func seedKeys(appLock: Bool, passcode: Bool = true, allow: Bool = true, asked: Asked) -> GatedSeedKeyProvider {
        GatedSeedKeyProvider(
            address: address, methodLabel: "Email & Password", network: "testnet",
            appLockApplies: { asked.appLockReads += 1; return appLock },
            seed: { [seed] in seed },
            ownerCheck: StellarOwnerCheck(canAuthenticate: { asked.passcodeChecks += 1; return passcode },
                                          authenticate: { _ in asked.prompts += 1; return allow }))
    }

    /// The sign-in challenge as the API writes it (§5.8).
    private var challenge: String {
        "DyorHQ Lite sign-in\nNetwork: testnet\nAddress: \(address)\nNonce: abcdefghijklmnop1234\nIssued: 2026-10-15T09:41:00.000Z"
    }

    func testTheSignInIsSignedWithNoPrompt() async throws {
        for appLock in [false, true] {
            let asked = Asked()
            let keys = seedKeys(appLock: appLock, asked: asked)
            XCTAssertTrue(keys.signsInSilently)
            let signature = try await keys.signInSignature(for: challenge)
            XCTAssertTrue(StellarSigner.verifyMessage(challenge, signature: signature, address: address), "a SEP-53 signature of the challenge")
            XCTAssertEqual(asked.prompts, 0, "the sign-in never asks for the owner")
            XCTAssertEqual(asked.appLockReads, 0, "nor reads App Lock")
        }
    }

    func testAnActionAsksOnceAndOnlyWhileAppLockApplies() async throws {
        let off = Asked()
        let quiet = try await seedKeys(appLock: false, asked: off).beginSigning(reason: "Confirm Swap")
        for step in ["Enable USDC", "Swap"] { _ = try await quiet.signer(reason: step) }
        XCTAssertEqual(off.appLockReads, 1, "App Lock is read when the action starts")
        XCTAssertEqual(off.prompts, 0, "App Lock off: no prompt at all")

        let on = Asked()
        let run = try await seedKeys(appLock: true, asked: on).beginSigning(reason: "Confirm Swap")
        XCTAssertEqual(on.prompts, 1, "App Lock on: Face ID or the passcode once, at Confirm")
        for step in ["Enable USDC", "Swap", "Deposit"] {
            let signer = try await run.signer(reason: step)
            XCTAssertEqual(signer.address, address)
        }
        XCTAssertEqual(on.prompts, 1, "every step of the action signs with no prompt of its own")

        run.end()
        do {
            _ = try await run.signer(reason: "After")
            XCTFail("a run that ended gives no signer")
        } catch {
            XCTAssertEqual(error as? LiteSession.Failure, .cancelled)
        }

        // The next action asks again: once per confirmed action.
        _ = try await seedKeys(appLock: true, asked: on).beginSigning(reason: "Confirm Send")
        XCTAssertEqual(on.prompts, 2)
    }

    func testAppLockFailsClosedWithoutADevicePasscode() async {
        let asked = Asked()
        do {
            _ = try await seedKeys(appLock: true, passcode: false, asked: asked).beginSigning(reason: "Confirm Swap")
            XCTFail("nothing is signed when the owner can't be verified")
        } catch {
            XCTAssertEqual(error as? StellarSigningFailure, .noDevicePasscode)
            // Monad's words, as the review shows them.
            XCTAssertEqual(LiteErrorText.describe(error), "App Lock needs a device passcode. Set one in iOS Settings, then try again.")
        }
        XCTAssertEqual(asked.passcodeChecks, 1)
        XCTAssertEqual(asked.prompts, 0)
    }

    func testACancelledPromptSignsNothing() async {
        let asked = Asked()
        do {
            _ = try await seedKeys(appLock: true, allow: false, asked: asked).beginSigning(reason: "Confirm Swap")
            XCTFail("a cancelled prompt starts no run")
        } catch {
            XCTAssertEqual(error as? LiteSession.Failure, .cancelled)
            XCTAssertTrue(StellarReviewRun.isCancellation(error), "the review leaves itself as it was: nothing was sent")
        }
        XCTAssertEqual(asked.prompts, 1)
    }

    func testShowingTheSecretKeyAlwaysAsks() async throws {
        for appLock in [false, true] {
            let asked = Asked()
            let secret = try await seedKeys(appLock: appLock, asked: asked).revealSecret(reason: "Show Stellar secret key")
            XCTAssertEqual(secret, try StellarSigner(seed: seed).secret)
            XCTAssertEqual(asked.prompts, 1, "whatever App Lock says")
            XCTAssertEqual(asked.appLockReads, 0)
        }
        let refused = Asked()
        do {
            _ = try await seedKeys(appLock: false, allow: false, asked: refused).revealSecret(reason: "Show Stellar secret key")
            XCTFail("a cancelled prompt shows nothing")
        } catch {
            XCTAssertEqual(error as? LiteSession.Failure, .cancelled)
        }
    }

    func testAnotherAccountsSeedSignsNothing() async throws {
        let asked = Asked()
        let keys = GatedSeedKeyProvider(address: address, methodLabel: "Imported wallet", network: "testnet",
                                        appLockApplies: { false }, seed: { [UInt8](repeating: 4, count: 32) })
        do {
            _ = try await keys.signInSignature(for: challenge)
            XCTFail("another account's seed")
        } catch {
            XCTAssertEqual(error as? KeyError, .badSeed)
        }
        let missing = GatedSeedKeyProvider(address: address, methodLabel: "Imported wallet", network: "testnet",
                                           appLockApplies: { false }, seed: { nil })
        let run = try await missing.beginSigning(reason: "Confirm Swap")
        do {
            _ = try await run.signer(reason: "Swap")
            XCTFail("no seed on this iPhone")
        } catch {
            XCTAssertEqual(error as? LiteSession.Failure, .keyNotOnDevice)
        }
        XCTAssertEqual(asked.prompts, 0)
    }

    func testThePasskeyProviderNeverConsultsAppLockAndAsksPerSignature() async throws {
        let words = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let stellar = try StellarDerivation.sep5(mnemonic: words).address
        let asked = Asked()
        let keys = try XCTUnwrap(DyorHQLiteKeys.make(method: .meraPasskey, stellar: stellar,
                                                     appLockApplies: { asked.appLockReads += 1; return true },
                                                     phrase: { _ in
                                                         await MainActor.run { asked.ceremonies += 1 }
                                                         return words
                                                     }))
        XCTAssertFalse(keys.signsInSilently)
        XCTAssertFalse(keys is GatedSeedKeyProvider)

        let run = try await keys.beginSigning(reason: "Confirm Swap")
        XCTAssertEqual(asked.ceremonies, 0, "starting the action asks nothing")
        for step in ["Enable USDC", "Swap"] {
            let signer = try await run.signer(reason: step)
            XCTAssertEqual(signer.address, stellar)
        }
        XCTAssertEqual(asked.ceremonies, 2, "the passkey once per signed step")
        XCTAssertEqual(asked.appLockReads, 0, "App Lock never applies to a passkey account")

        // The sign-in can't be signed silently: it needs the passkey (`LiteSession.signIn()`).
        do {
            _ = try await keys.signInSignature(for: challenge)
            XCTFail("a passkey account's sign-in needs its passkey")
        } catch {
            XCTAssertEqual(error as? LiteSession.Failure, LiteSession.Failure.needsPasskey)
        }
        XCTAssertEqual(asked.ceremonies, 2)
    }

    func testEachSignInMethodGetsItsProvider() {
        let none: @Sendable (String) async throws -> String = { _ in "" }
        for method in [Session.Method.emailPassword, .imported] {
            XCTAssertTrue(DyorHQLiteKeys.make(method: method, stellar: address, appLockApplies: { true }, phrase: none) is GatedSeedKeyProvider, "\(method)")
        }
        XCTAssertTrue(DyorHQLiteKeys.make(method: .meraPasskey, stellar: address, appLockApplies: { true }, phrase: none) is PhraseKeyProvider)
        for method in [Session.Method.apple, .google, .email, .passkey, .watchOnly] {
            XCTAssertNil(DyorHQLiteKeys.make(method: method, stellar: address, appLockApplies: { true }, phrase: none), "\(method)")
        }
    }
}
