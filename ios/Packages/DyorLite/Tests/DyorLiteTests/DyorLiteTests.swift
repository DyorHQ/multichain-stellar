@testable import DyorLite
import StellarKit
import XCTest

final class KeyProviderTests: XCTestCase {
    private let phrase = "illness spike retreat truth genius clock brain pass fit cave bargain toe"
    private let address = "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"

    func testPhraseProviderDerivesTheSEP5Account() async throws {
        let phrase = self.phrase
        let p = PhraseKeyProvider(address: address, methodLabel: "Test") { _ in phrase }
        let signer = try await p.signer(reason: "test")
        XCTAssertEqual(signer.address, address)
    }

    func testPhraseProviderRefusesAPhraseForAnotherAccount() async {
        let phrase = self.phrase
        let p = PhraseKeyProvider(address: "GA6HCMBLTZS5VYYBCATRBRZ3BZJMAFUDKYYF6AH6MVCMGWMRDNSWJPIH", methodLabel: "Test") { _ in phrase }
        do {
            _ = try await p.signer(reason: "test")
            XCTFail("signed with the wrong account's phrase")
        } catch {}
    }

    func testWatchOnlyNeverSigns() async {
        let p = WatchOnlyKeyProvider(address: address)
        XCTAssertFalse(p.canSign)
        do {
            _ = try await p.signer(reason: "test")
            XCTFail()
        } catch {}
    }

    @MainActor
    func testLimitsMapAssetIdsToContracts() {
        let env = LiteEnvironment(apiURL: URL(string: "https://example.invalid/lite")!, buildNumber: 1)
        let store = LiteStore(env: env, keys: WatchOnlyKeyProvider(address: address))
        // Without config, an id passes through unchanged (launch tokens are already contract ids).
        XCTAssertEqual(store.limit("CABC", "10"), ["CABC": 10])
    }
}
