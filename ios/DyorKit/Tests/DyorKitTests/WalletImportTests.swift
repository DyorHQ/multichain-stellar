import BigInt
import XCTest
@testable import DyorKit

/// Proves the on-device wallet import against published test vectors: the Anvil/Hardhat default mnemonic and the
/// canonical BIP-39 "abandon…about" seed, plus a raw private key, plus a sign→recover round-trip that confirms
/// signatures are made over the exact keccak preimage (not a re-hashed one).
final class WalletImportTests: XCTestCase {
    // Anvil / Hardhat default mnemonic — its accounts are fixed and widely published.
    let anvil = "test test test test test test test test test test test junk"

    func testPrivateKeyToAddress() {
        // Anvil account #0 private key → its address.
        let account = Secp256k1Account(privateKeyHex: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
        XCTAssertEqual(account?.address, Address("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"))
    }

    func testMnemonicDerivesAnvilAccounts() {
        let account0 = WalletImport.account(fromMnemonic: anvil, accountIndex: 0)
        XCTAssertEqual(account0?.address, Address("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"))
        XCTAssertEqual(account0?.privateKey.hexString, "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")

        let account1 = WalletImport.account(fromMnemonic: anvil, accountIndex: 1)
        XCTAssertEqual(account1?.address, Address("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"))
        XCTAssertEqual(account1?.privateKey.hexString, "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
    }

    func testCanonicalAbandonVector() {
        // The all-zero-entropy mnemonic; m/44'/60'/0'/0/0 is a well-known fixture.
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let account = WalletImport.account(fromMnemonic: phrase, accountIndex: 0)
        XCTAssertEqual(account?.address, Address("0x9858EfFD232B4033E47d90003D41EC34EcaEda94"))
        XCTAssertEqual(account?.privateKey.hexString, "0x1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727")
    }

    func testMnemonicValidation() {
        XCTAssertTrue(WalletImport.isValidMnemonic(anvil))
        XCTAssertTrue(WalletImport.isValidMnemonic("  TEST test\ttest test test test test test test test test junk "))
        // Wrong checksum (last word swapped).
        XCTAssertFalse(WalletImport.isValidMnemonic("test test test test test test test test test test test test"))
        // Not a word-list word.
        XCTAssertFalse(WalletImport.isValidMnemonic("hello test test test test test test test test test test junk"))
        // Wrong length.
        XCTAssertFalse(WalletImport.isValidMnemonic("test test test"))
        // All-abandon 12 words fails the checksum.
        XCTAssertFalse(WalletImport.isValidMnemonic(Array(repeating: "abandon", count: 12).joined(separator: " ")))
    }

    func testRejectsBadPrivateKeys() {
        XCTAssertNil(Secp256k1Account(privateKey: Data(repeating: 0, count: 32)))        // zero
        XCTAssertNil(Secp256k1Account(privateKey: Data(repeating: 0xFF, count: 32)))     // >= n
        XCTAssertNil(Secp256k1Account(privateKey: Data(repeating: 1, count: 31)))        // wrong length
        XCTAssertNil(Secp256k1Account(privateKeyHex: "0xnothex"))
    }

    func testSignRecoverRoundTrip() throws {
        let account = try XCTUnwrap(WalletImport.account(fromMnemonic: anvil))
        let hash = Keccak.hash256(Data("DyorHQ signing test".utf8))
        let signature = try account.sign(hash32: hash)
        XCTAssertEqual(signature.count, 65)
        let v = signature[64]
        XCTAssertTrue(v == 27 || v == 28, "v should be 27/28, was \(v)")
        // The signature must recover to the signer — this only holds if it is over exactly `hash`.
        XCTAssertEqual(Secp256k1Account.recover(hash32: hash, signature: signature), account.address)
    }

    func testPersonalSignRecovers() throws {
        let account = try XCTUnwrap(WalletImport.account(fromMnemonic: anvil))
        let message = Data("Sign in to DyorHQ".utf8)
        let signature = try account.signMessage(message)
        // Rebuild the EIP-191 digest and confirm recovery matches — proves the prefix + length framing.
        let prefixed = Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8) + message
        XCTAssertEqual(Secp256k1Account.recover(hash32: Keccak.hash256(prefixed), signature: signature), account.address)
    }

    func testSignatureIsCanonicalLowS() throws {
        let account = try XCTUnwrap(WalletImport.account(fromMnemonic: anvil))
        let signature = try account.sign(hash32: Keccak.hash256(Data("low-s".utf8)))
        let s = BigUInt(signature[32..<64])
        XCTAssertLessThanOrEqual(s, Secp256k1Account.curveOrder / 2, "s must be in the lower half of the order")
    }
}
