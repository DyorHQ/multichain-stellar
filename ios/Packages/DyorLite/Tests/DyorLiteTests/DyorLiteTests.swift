@testable import DyorLite
import StellarKit
import XCTest

/// The key providers (decision 6, §7.2): a passkey (phrase) account is never silent and asks for its passkey once per
/// signature; a seed account signs the sign-in with no prompt and asks App Lock once per action, only when it applies;
/// showing the secret always asks; watch-only refuses everything; a run gives no signer once it has ended.
final class KeyProviderTests: XCTestCase {
    private let phrase = "illness spike retreat truth genius clock brain pass fit cave bargain toe"
    private let address = "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"
    private let challenge = "DyorHQ Lite sign-in\nNetwork: testnet\nAddress: G\nNonce: n0nce-xxxxxxxxxxxxxxxx\nIssued: 2026-10-14T09:41:00.000Z"

    func testAPhraseProviderAsksItsCeremonyOncePerSignature() async throws {
        let phrase = self.phrase
        let tally = Tally()
        let p = PhraseKeyProvider(address: address, methodLabel: "Test") { _ in
            tally.add("passkey")
            return phrase
        }
        XCTAssertFalse(p.signsInSilently)
        do {
            _ = try await p.signInSignature(for: challenge)
            XCTFail("a passkey account signed in without its passkey")
        } catch {
            XCTAssertEqual(error as? LiteSession.Failure, .needsPasskey)
        }
        let run = try await p.beginSigning(reason: "Confirm Swap")
        XCTAssertEqual(tally.prompts, 0, "beginning asks nothing")
        let first = try await run.signer(reason: "Enable USDC")
        let second = try await run.signer(reason: "Swap")
        XCTAssertEqual(first.address, address)
        XCTAssertEqual(second.address, address)
        XCTAssertEqual(tally.prompts, 2, "one ceremony per signature")
        run.end()
        do {
            _ = try await run.signer(reason: "Swap")
            XCTFail("a signer after the run ended")
        } catch {}
        XCTAssertEqual(tally.prompts, 2, "and no ceremony either")
    }

    func testAPhraseProviderRefusesAPhraseForAnotherAccount() async throws {
        let phrase = self.phrase
        let p = PhraseKeyProvider(address: "GA6HCMBLTZS5VYYBCATRBRZ3BZJMAFUDKYYF6AH6MVCMGWMRDNSWJPIH", methodLabel: "Test") { _ in phrase }
        let run = try await p.beginSigning(reason: "test")
        do {
            _ = try await run.signer(reason: "test")
            XCTFail("signed with the wrong account's phrase")
        } catch {
            XCTAssertEqual(error as? KeyError, .badMnemonic)
        }
    }

    func testASeedProviderSignsTheSignInSilentlyAndAsksAppLockOncePerActionOnlyWhenItApplies() async throws {
        let tally = Tally()
        let seed = TestAccount.seed
        let appLock = Setting(true)
        let p = StoredSeedKeyProvider(address: TestAccount.seedSigner.address, methodLabel: "Test", network: "testnet", appLock: { appLock.value },
                                      seed: { tally.add("seedRead"); return seed }, authenticate: { _ in tally.add("appLock") })
        XCTAssertTrue(p.signsInSilently)
        let signature = try await p.signInSignature(for: challenge)
        XCTAssertTrue(StellarSigner.verifyMessage(challenge, signature: signature, address: TestAccount.seedSigner.address), "a SEP-53 signature")
        XCTAssertEqual(tally("appLock"), 0, "the sign-in never prompts")
        XCTAssertEqual(tally("seedRead"), 1)

        let run = try await p.beginSigning(reason: "Confirm Swap")
        XCTAssertEqual(tally("appLock"), 1, "App Lock once, at the start of the action")
        _ = try await run.signer(reason: "Enable USDC")
        _ = try await run.signer(reason: "Swap")
        XCTAssertEqual(tally("appLock"), 1, "and never per step")
        XCTAssertEqual(tally("seedRead"), 3, "each step reads the seed for itself")
        run.end()

        // The setting is read when Confirm is tapped: turned off in Profile › Security, the same provider asks nothing at
        // the next action, and asks again once it is back on.
        appLock.value = false
        _ = try await p.beginSigning(reason: "Confirm Swap").signer(reason: "Swap")
        XCTAssertEqual(tally("appLock"), 1, "App Lock off: no prompt")
        appLock.value = true
        _ = try await p.beginSigning(reason: "Confirm Swap").signer(reason: "Swap")
        XCTAssertEqual(tally("appLock"), 2, "App Lock on again: one prompt at the next Confirm")

        appLock.value = false
        let secret = try await p.revealSecret(reason: "Show your Stellar secret key")
        XCTAssertEqual(secret, TestAccount.seedSigner.secret)
        XCTAssertEqual(tally("appLock"), 3, "showing the secret always asks, App Lock or not")
    }

    func testASeedProviderWithoutItsSeedSignsNothing() async throws {
        let p = StoredSeedKeyProvider(address: TestAccount.seedSigner.address, methodLabel: "Test", network: "testnet", appLock: { false },
                                      seed: { nil }, authenticate: { _ in })
        do {
            _ = try await p.signInSignature(for: challenge)
            XCTFail("signed without a seed")
        } catch {
            XCTAssertEqual(error as? KeyError, .badSeed)
        }
        let other = StoredSeedKeyProvider(address: TestAccount.passkeyAddress, methodLabel: "Test", network: "testnet", appLock: { false },
                                          seed: { TestAccount.seed }, authenticate: { _ in })
        do {
            _ = try await other.beginSigning(reason: "x").signer(reason: "x")
            XCTFail("signed with another account's seed")
        } catch {
            XCTAssertEqual(error as? KeyError, .badSeed)
        }
    }

    func testWatchOnlyNeverSigns() async {
        let p = WatchOnlyKeyProvider(address: address)
        XCTAssertFalse(p.canSign)
        XCTAssertFalse(p.signsInSilently)
        do {
            _ = try await p.beginSigning(reason: "test")
            XCTFail()
        } catch {}
        do {
            _ = try await p.signInSignature(for: challenge)
            XCTFail()
        } catch {}
    }

    @MainActor
    func testLimitsMapAssetIdsToContracts() {
        let env = LiteEnvironment(apiURL: URL(string: "https://example.invalid/lite")!, buildNumber: 1)
        let store = LiteStore(env: env, backend: TestBackend(api: LiteAPI(baseURL: env.apiURL)), address: address, monad: nil, config: nil)
        // Without config, an id passes through unchanged (launch tokens are already contract ids).
        XCTAssertEqual(store.limit("CABC", "10"), ["CABC": 10])
    }

    func testTheEnvironmentPinsTheMediaBaseUntilTheHostSetsIt() {
        let env = LiteEnvironment(apiURL: URL(string: "http://127.0.0.1:9/lite")!, buildNumber: 1)
        XCTAssertEqual(env.mediaBase.absoluteString, "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/lite-media/")
        XCTAssertNil(env.renderBase)
    }

    /// The host's activity recorder takes settled actions; its tests make their own (§12.2).
    func testAHostCanMakeASettledAction() {
        let at = Date(timeIntervalSince1970: 1_791_970_860)
        let settled = LiteSettledAction(planId: "plan-1", kind: "swap", title: "Swap complete", body: "Swapped 10 XLM → 1.89 USDC", section: .spot,
                                        reference: "stellar:swap", hashes: [String(repeating: "a", count: 64)], at: at)
        XCTAssertEqual(settled.planId, "plan-1")
        XCTAssertEqual(settled.kind, "swap")
        XCTAssertEqual(settled.section, .spot)
        XCTAssertEqual(settled.reference, "stellar:swap")
        XCTAssertEqual(settled.at, at)
    }

    /// A Monad wallet written before previews prices nothing: the bridge review shows no Monad fee.
    func testAMonadBridgeWithoutPreviewsPricesNothing() async throws {
        struct OldBridge: LiteMonadBridge {
            let monadAddress = "0x0000000000000000000000000000000000000001"
            func send(_ steps: [EvmStep]) async throws -> String { "0x" }
        }
        let preview = try await OldBridge().preview([])
        XCTAssertNil(preview)
    }
}
