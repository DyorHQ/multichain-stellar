import CryptoKit
import XCTest
@testable import DyorKit

/// The native Mera implementation against vectors produced with `@category-labs/mera` 0.2.0, `@scure/bip39` and
/// `@scure/bip32` in Node: same salt, same phrase, same address. `scripts/mera-parity/parity.mjs` reads the literals in
/// this file (the PRFs, phrase, seed, keys, addresses and the sealed vault) and recomputes each one with the pinned
/// library, so a vector changed here without the library agreeing fails there. It finds them by shape: keep each
/// literal in its current form, or update the script's patterns with it.
final class MeraTests: XCTestCase {
    let prf = Data(hex: "0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!

    func testDefaultSaltMatchesTheLibrary() {
        XCTAssertEqual(Mera.accountSalt.hexString, "0x896d46ac4ac191885c46137439db7bb52fb05cff3ecd34af7cdae0a1e0c00db9")
        XCTAssertNotEqual(Mera.utilitySalt, Mera.accountSalt)
        XCTAssertEqual(Mera.salt("mera.prf.salt.v1"), Mera.accountSalt)
    }

    func testEntropyToMnemonicAndSeed() {
        let phrase = Mera.mnemonic(entropy: prf)
        XCTAssertEqual(phrase, "abandon amount liar amount expire adjust cage candy arch gather drum bullet absurd math era live bid rhythm alien crouch range attend journey unaware")
        XCTAssertTrue(WalletImport.isValidMnemonic(phrase!))
        XCTAssertEqual(Mnemonic.seed(phrase: phrase!)?.hexString, "0x0a6d060f6242aece4b074e48e7d8166f792a9b2bb7b295fa5ac289eda7647290c3d80e7436d6e9e34e72769c06f6582192d0b57ae4a97e9e24c8972a770a57d9")
        // Standard BIP-39 vector: 16 zero bytes → "abandon" × 11 + "about".
        XCTAssertEqual(Mera.mnemonic(entropy: Data(repeating: 0, count: 16)), Array(repeating: "abandon", count: 11).joined(separator: " ") + " about")
        XCTAssertNil(Mera.mnemonic(entropy: Data(repeating: 0, count: 17)))
    }

    func testEvmAccountsMatchTheLibrary() {
        let a0 = Mera.evmAccount(prf: prf)!
        XCTAssertEqual(a0.privateKey.hexString, "0xe3b99b954c842dbd1e61148af4c295e15fda6d41d1633fd10fab2c6090f42669")
        XCTAssertEqual(a0.address.checksummed, "0xF9297b542BDb5DA50C364f9AE4Cbe1F3933bA40F")
        let a1 = Mera.evmAccount(prf: prf, index: 1)!
        XCTAssertEqual(a1.address.checksummed, "0xA586108FeA48130F1e9FAa634Dace29867629A39")
        XCTAssertNil(Mera.evmAccount(prf: Data(repeating: 1, count: 31)))
    }

    func testVaultKeyAndCiphertextMatchWebCrypto() throws {
        let vaultPRF = Data(hex: "0x202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")!
        XCTAssertEqual(Mera.Vault.key(prf: vaultPRF).withUnsafeBytes { Data($0) }.hexString, "0xd574b00b8aa99c62632a6311f25f8013b23397c8903bbaf65079aec3e710bc71")
        XCTAssertEqual(Mera.Vault.key(prf: prf).withUnsafeBytes { Data($0) }.hexString, "0x08c0ce37bd9a24a5d348d42921f2e897612214c5e7f736e4a61701dc33b30d02")
        let nonce = Data(hex: "0x404142434445464748494a4b")!
        let salt = Data(repeating: 7, count: 32)
        let vault = try Mera.Vault.seal(secret: Data("hello mera".utf8), prf: vaultPRF, prfSalt: salt, credentialID: Data([1, 2, 3]), nonce: nonce)
        XCTAssertEqual(Mera.Base64URL.decode(vault.ciphertext)?.hexString, "0xbffd7689560c5bf20fc762068f47d3e063ad1bc620ef3d80b517")
        XCTAssertEqual(vault.version, 1)
        XCTAssertEqual(vault.credential.credentialId, "AQID")
        XCTAssertTrue(vault.isWellFormed)
        XCTAssertEqual(try Mera.Vault.open(vault, prf: vaultPRF), Data("hello mera".utf8))
        // Wrong PRF (another passkey) or a flipped byte must fail, never return garbage.
        XCTAssertThrowsError(try Mera.Vault.open(vault, prf: prf))
        var tampered = vault
        var bytes = Mera.Base64URL.decode(vault.ciphertext)!
        bytes[0] ^= 0x01
        tampered.ciphertext = Mera.Base64URL.encode(bytes)
        XCTAssertThrowsError(try Mera.Vault.open(tampered, prf: vaultPRF))
        // JSON round trip keeps the library's field names.
        let json = try JSONEncoder().encode(vault)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"prfSalt\""))
        XCTAssertEqual(try JSONDecoder().decode(Mera.SecretVault.self, from: json), vault)
    }

    func testDerivedKeysAreNamespaced() throws {
        let trading = Mera.derivedKey(prf: prf, purpose: Mera.Purpose.perplTrading)
        let state = Mera.derivedKey(prf: prf, purpose: Mera.Purpose.state)
        XCTAssertEqual(trading.count, 32)
        XCTAssertNotEqual(trading, state)
        XCTAssertEqual(trading, Mera.derivedKey(prf: prf, purpose: Mera.Purpose.perplTrading)) // deterministic
        XCTAssertNotEqual(trading, Mera.derivedKey(prf: Data(repeating: 9, count: 32), purpose: Mera.Purpose.perplTrading))
        let key = try Mera.ed25519Key(prf: prf, purpose: Mera.Purpose.perplTrading)
        XCTAssertEqual(key.rawRepresentation, trading)
        XCTAssertEqual(key.publicKey.rawRepresentation.count, 32)
    }

    /// The rpId is a constant, and the app's associated-domains entitlement names exactly that host for passkeys and
    /// exactly the Moment link host for universal links — nothing else, and no `?mode=developer`, which never
    /// associates in a distribution build. The two stay apart: applinks never on the passkey host (its pages would be
    /// creator content on the rpId origin), webcredentials never on the link host.
    func testRelyingPartyMatchesTheEntitlement() throws {
        XCTAssertEqual(Mera.relyingParty, "accounts.dyorhq.fun")
        XCTAssertEqual(MomentLink.host, "dyorhq.fun")
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        guard let spec = try? String(contentsOf: ios.appendingPathComponent("project.yml"), encoding: .utf8) else {
            throw XCTSkip("ios/project.yml is not in this checkout")
        }
        let settings = spec.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let lines = settings.filter { $0.contains("com.apple.developer.associated-domains") }
        XCTAssertEqual(lines.count, 1)
        // The whole bracketed list, item by item, so nothing extra can hide in it (single-quoted or bare YAML items).
        let line = String(lines.first ?? "")
        let list = line.drop { $0 != "[" }.dropFirst().prefix { $0 != "]" }
        let items = list.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
        XCTAssertTrue(line.trimmingCharacters(in: .whitespaces).hasSuffix("]"))
        XCTAssertEqual(items, ["webcredentials:\(Mera.relyingParty)", "applinks:\(MomentLink.host)"])
        XCTAssertFalse(settings.contains { $0.contains("mode=developer") })
        // XcodeGen writes the entitlements file from project.yml; the checked-in copy must be regenerated to match.
        let entitlements = try String(contentsOf: ios.appendingPathComponent("DyorHQ/DyorHQ.entitlements"), encoding: .utf8)
        XCTAssertTrue(entitlements.contains("<string>webcredentials:\(Mera.relyingParty)</string>"))
        XCTAssertTrue(entitlements.contains("<string>applinks:\(MomentLink.host)</string>"))
        XCTAssertEqual(entitlements.components(separatedBy: "<string>webcredentials:").count, 2)
        XCTAssertEqual(entitlements.components(separatedBy: "<string>applinks:").count, 2)
        XCTAssertFalse(entitlements.contains("mode=developer"))
    }

    func testBase64URL() {
        let data = Data([0xfb, 0xff, 0xfe, 0x00])
        let text = Mera.Base64URL.encode(data)
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="))
        XCTAssertEqual(Mera.Base64URL.decode(text), data)
    }
}
