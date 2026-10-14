import XCTest
@testable import DyorKit

/// The email + password wallet derivation. Every expected value was computed independently of this code — Python's
/// hashlib/hmac (PBKDF2, SHA-256, an RFC 5869 HKDF checked against the RFC's test case 1) with eth_account for
/// BIP-39/BIP-32 and addresses, cross-checked with `cast wallet address` — and the legacy addresses also with the
/// app's PasswordWallet.swift as it was before the derivation moved here. All inputs are public test values.
final class EmailWalletTests: XCTestCase {
    private func hex(_ data: Data) -> String { String(data.hexString.dropFirst(2)) }

    // MARK: Legacy — must never change (it defines the address of every account created before v2)

    func testLegacyDerivationIsUnchanged() throws {
        let vectors: [(email: String, password: String, seed: String, address: String)] = [
            ("  Alice.Test@Example.com \n", "Correct-Horse-Battery-9!",
             "ae3a32efcd63fdefae6f1777ac66baf43ce15c0b76da6741cca91f435b52cb2c", "0x3C6119B96D03a76bF59195F224057024Ee40Ae1F"),
            ("vector@dyorhq.test", "Tr0ub4dor&3-long-enough",
             "d133b767318be0fc5a550ffb664f0e3f176ab0047c67171b5d66ad246029f4e7", "0x2014b8247dFC23084227F4E032db677Df70D1307"),
        ]
        for vector in vectors {
            let seed = try XCTUnwrap(EmailWallet.legacySeed(email: vector.email, password: vector.password))
            XCTAssertEqual(hex(seed), vector.seed)
            XCTAssertEqual(EmailWallet.legacyAccount(seed: seed)?.address.checksummed, vector.address)
        }
    }

    func testLegacySeedNormalizesTheEmailAndRejectsEmptyInput() {
        XCTAssertEqual(EmailWallet.normalize("  Alice.Test@Example.com \n"), "alice.test@example.com")
        XCTAssertNil(EmailWallet.legacySeed(email: "  \n", password: "x"))
        XCTAssertNil(EmailWallet.legacySeed(email: "a@b.co", password: ""))
    }

    // MARK: v2

    func testPepperInputs() throws {
        let seed = try XCTUnwrap(Data(hex: "ae3a32efcd63fdefae6f1777ac66baf43ce15c0b76da6741cca91f435b52cb2c"))
        let input = EmailWallet.pepperInput(email: "  Alice.Test@Example.com \n", seed: seed)
        XCTAssertEqual(hex(input.e), "2ecf504cb940af9ff3e0171edd90a0849991bb2273583a0cb2e46391cecc63ee")
        XCTAssertEqual(hex(input.t), "f8d89001cb68ed79dd4abba88684bcf451d81ded1b82f8b2688ada25d9c872c5")
        // e depends only on the (normalized) email; t only on the seed.
        XCTAssertEqual(EmailWallet.pepperInput(email: "alice.test@example.com", seed: Data(count: 32)).e, input.e)
        let other = try XCTUnwrap(Data(hex: "d133b767318be0fc5a550ffb664f0e3f176ab0047c67171b5d66ad246029f4e7"))
        let second = EmailWallet.pepperInput(email: "vector@dyorhq.test", seed: other)
        XCTAssertEqual(hex(second.e), "2783f7c835521d160a765f298b86317c13ec8e2ad98ba8f4c795416ac90a11cf")
        XCTAssertEqual(hex(second.t), "b9ac5338b8356ebc97b0dccfbfa9bc797fc5c27d3e41be74d41f5057cfecd7aa")
    }

    /// e as the `email-pepper` function recomputes it from the email Privy attests (its normalizeEmail/emailHash):
    /// the same fixture drives the server's tests, so the verified budget opens only when both sides agree byte for
    /// byte — including where Swift's trim/lowercase differ from JavaScript's (U+200B, U+FEFF, final sigma).
    func testEmailHashMatchesTheServerVectors() throws {
        struct Fixture: Decodable {
            struct Vector: Decodable { let email: String; let normalized: String; let e: String }
            let label: String
            let vectors: [Vector]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "email-pepper", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.label, "dyorhq/email-pepper/v1/email:")
        XCTAssertEqual(fixture.vectors.count, 6)
        for vector in fixture.vectors {
            XCTAssertEqual(EmailWallet.normalize(vector.email), vector.normalized, vector.e)
            XCTAssertEqual(hex(EmailWallet.emailHash(vector.email)), vector.e)
            XCTAssertEqual(EmailWallet.pepperInput(email: vector.email, seed: Data(count: 32)).e, EmailWallet.emailHash(vector.email))
        }
        // Spot-check that the fixture decodes the invisible characters it is about.
        XCTAssertTrue(fixture.vectors[2].email.unicodeScalars.contains("\u{200B}"))
        XCTAssertTrue(fixture.vectors[3].normalized.unicodeScalars.last == "\u{FEFF}")
        XCTAssertEqual(EmailWallet.normalize("ΟΔΥΣΣΕΥΣ"), "οδυσσευσ")
    }

    /// Fixed S = 00 01 … 1f and p = a5 × 32: HKDF-SHA256(S || p, salt "dyorhq/email-wallet/v2", info "secp256k1").
    private let fixedSeed = Data(0..<32)
    private let fixedPepper = Data(repeating: 0xA5, count: 32)
    private let attemptKeys = [
        "bcaf22c2be30d9d293ca361d898822708113918d2c187ae38b07ed565b3985f3", // info "secp256k1"
        "aa9c2a53da9258d0d963d13c8fad795fac98189daf581a87eca8f966d32575c7", // info "secp256k1/1"
        "df8c197ecb269d53066cf7dc8cebdc92f3ff995affe9f03ac9ce22499922aaab", // info "secp256k1/2"
    ]

    func testV2DerivationVector() throws {
        XCTAssertEqual(try XCTUnwrap(EmailWallet.v2PrivateKey(seed: fixedSeed, pepper: fixedPepper)).hexString, "0x" + attemptKeys[0])
        let account = try XCTUnwrap(EmailWallet.v2Account(seed: fixedSeed, pepper: fixedPepper))
        XCTAssertEqual(account.address.checksummed, "0x4a9cB688670cF5aa94AA1F6359dA269a9acbB007")
        // The pepper matters: the same seed without it (or with another) is a different wallet.
        XCTAssertNotEqual(EmailWallet.v2Account(seed: fixedSeed, pepper: Data(count: 32))?.address, account.address)
    }

    func testV2SkipsCandidatesThatAreNotValidKeys() throws {
        var seen: [String] = []
        let key = EmailWallet.v2PrivateKey(seed: fixedSeed, pepper: fixedPepper) { candidate in
            seen.append(self.hex(candidate))
            return seen.count == 3 // reject info "secp256k1" and "secp256k1/1"
        }
        XCTAssertEqual(seen, attemptKeys)
        XCTAssertEqual(key.map(hex), attemptKeys[2])
        let account = try XCTUnwrap(key.flatMap { Secp256k1Account(privateKey: $0) })
        XCTAssertEqual(account.address.checksummed, "0x918a929B551058671396eA60383d7e5FAF735314")
    }

    func testV2GivesUpInsteadOfLoopingForever() {
        var attempts = 0
        XCTAssertNil(EmailWallet.v2PrivateKey(seed: fixedSeed, pepper: fixedPepper) { _ in attempts += 1; return false })
        XCTAssertEqual(attempts, EmailWallet.maxV2Attempts)
    }

    func testValidPrivateKeyRange() throws {
        let n = Secp256k1Account.curveOrder.serialize()
        XCTAssertFalse(EmailWallet.isValidPrivateKey(Data(count: 32)))                        // 0
        XCTAssertTrue(EmailWallet.isValidPrivateKey(Data(count: 31) + Data([1])))             // 1
        XCTAssertFalse(EmailWallet.isValidPrivateKey(n))                                      // n
        XCTAssertTrue(EmailWallet.isValidPrivateKey(n.dropLast() + Data([n.last! - 1])))      // n - 1
        XCTAssertFalse(EmailWallet.isValidPrivateKey(Data(repeating: 0xFF, count: 32)))       // > n
        XCTAssertFalse(EmailWallet.isValidPrivateKey(Data(repeating: 0x01, count: 31)))       // wrong length
    }
}
