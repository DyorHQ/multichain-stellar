import Foundation
@testable import StellarCore
import XCTest

private struct KeyVectors: Decodable {
    struct Sep5: Decodable { let mnemonic: String; let index: UInt32; let address: String; let secret: String }
    struct Sep53: Decodable { let secret: String; let message: String; let signature: String }
    struct Sac: Decodable { let asset: String; let network: String; let id: String }
    let sep5: [Sep5]
    let sep53: Sep53
    let sac: [Sac]
}

private struct VerifierVector: Decodable {
    struct Expect: Decodable { let ok: Bool; let reason: String?; let outflow: [String: String]? }
    struct Decoded: Decodable { let source: String; let fee: UInt32; let seq: String; let maxTime: UInt64; let ops: [String] }
    let name: String
    let envelope: String
    let intent: Intent
    let user: String
    let sponsor: String
    let allowed: [String]
    let now: Double
    let expect: Expect
    let decoded: Decoded
}

private func loadVectors<T: Decodable>(_ name: String) throws -> T {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Vectors"))
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

final class StrKeyTests: XCTestCase {
    func testRoundTripsAndChecksums() throws {
        let g = "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"
        let raw = try StrKey.decode(.accountID, g)
        XCTAssertEqual(raw.count, 32)
        XCTAssertEqual(StrKey.accountID(raw), g)
        let c = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
        XCTAssertEqual(StrKey.contractID(try StrKey.decode(.contract, c)), c)
        // One flipped character breaks the checksum; a G key is not a contract.
        XCTAssertThrowsError(try StrKey.decode(.accountID, "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ7"))
        XCTAssertThrowsError(try StrKey.decode(.contract, g))
        XCTAssertFalse(StrKey.isValid(.accountID, "not a key"))
    }
}

final class KeyTests: XCTestCase {
    func testSep5OfficialVector() throws {
        let v: KeyVectors = try loadVectors("keys")
        for k in v.sep5 {
            let signer = try StellarDerivation.sep5(mnemonic: k.mnemonic, index: k.index)
            XCTAssertEqual(signer.address, k.address)
            XCTAssertEqual(signer.secret, k.secret)
        }
    }

    func testMnemonicGenerationAndChecksum() throws {
        XCTAssertEqual(Mnemonic.words.count, 2048)
        let phrase = try XCTUnwrap(Mnemonic.phrase(entropy: [UInt8](repeating: 0, count: 32)))
        XCTAssertEqual(phrase.split(separator: " ").count, 24)
        XCTAssertTrue(phrase.hasSuffix("art")) // BIP-39 vector: 32 zero bytes → "abandon … art"
        XCTAssertTrue(Mnemonic.isValid(phrase))
        XCTAssertFalse(Mnemonic.isValid(phrase.replacingOccurrences(of: "art", with: "zoo")))
        XCTAssertTrue(Mnemonic.isValid("illness spike retreat truth genius clock brain pass fit cave bargain toe"))
    }

    func testSep53SignaturesInteroperate() throws {
        let v: KeyVectors = try loadVectors("keys")
        let signer = try StellarSigner(secret: v.sep53.secret)
        let digest = SHA256Bridge.hash(Array(("Stellar Signed Message:\n" + v.sep53.message).utf8))
        // The JS signature verifies here, and ours verifies too (CryptoKit's ed25519 may be randomized).
        XCTAssertTrue(StellarSigner.verify(address: signer.address, message: digest, signature: [UInt8](Data(base64Encoded: v.sep53.signature)!)))
        let mine = try signer.signMessage(v.sep53.message)
        XCTAssertTrue(StellarSigner.verify(address: signer.address, message: digest, signature: [UInt8](Data(base64Encoded: mine)!)))
    }

    func testDerivationsAreDomainSeparated() throws {
        let seed = [UInt8](repeating: 1, count: 32)
        let pepper = [UInt8](repeating: 2, count: 32)
        let a = try StellarDerivation.emailV2(seed: seed, pepper: pepper)
        let b = try StellarDerivation.emailV2(seed: seed, pepper: pepper)
        XCTAssertEqual(a.address, b.address)
        XCTAssertNotEqual(a.address, try StellarDerivation.fromSecp256k1(privateKey: seed).address)
        XCTAssertNotEqual(a.address, try StellarDerivation.emailV2(seed: seed, pepper: [UInt8](repeating: 3, count: 32)).address)
    }

    func testAssetContractIDs() throws {
        let v: KeyVectors = try loadVectors("keys")
        for s in v.sac {
            let network: StellarNetwork = s.network == "mainnet" ? .mainnet : .testnet
            let asset: Asset
            if s.asset == "native" { asset = .native } else {
                let parts = s.asset.split(separator: ":").map(String.init)
                asset = .credit(code: parts[0], issuer: parts[1])
            }
            XCTAssertEqual(AssetContract.id(asset, network: network), s.id, s.asset)
        }
    }
}

final class AmountTests: XCTestCase {
    func testParseAndFormat() {
        XCTAssertEqual(Amount.parse("12.5"), 125_000_000)
        XCTAssertEqual(Amount.parse("0.0000001"), 1)
        XCTAssertEqual(Amount.parse("1.123456789"), 11_234_567)
        XCTAssertNil(Amount.parse("1.2.3"))
        XCTAssertNil(Amount.parse("-1"))
        XCTAssertNil(Amount.parse(""))
        XCTAssertEqual(Amount.format(Int64(125_000_000)), "12.5")
        XCTAssertEqual(Amount.format(Int64(1)), "0.0000001")
    }
}

final class VerifierVectorTests: XCTestCase {
    /// Every vector the TypeScript verifier judged: the Swift verifier must reach the same verdict and outflow.
    func testAgreesWithTheServerVerifier() throws {
        let vectors: [VerifierVector] = try loadVectors("verifier")
        XCTAssertGreaterThan(vectors.count, 30)
        var compared = 0
        for v in vectors {
            let envelope: TransactionEnvelope
            do {
                envelope = try TransactionEnvelope(base64: v.envelope)
            } catch {
                // Swift's decoder only knows the operations Lite uses; anything else can never be signed.
                XCTAssertFalse(v.expect.ok, "\(v.name): decode failed (\(error)) but the server accepted it")
                continue
            }
            // Decoding agrees with stellar-sdk.
            XCTAssertEqual(envelope.transaction.source, v.decoded.source, v.name)
            XCTAssertEqual(envelope.transaction.fee, v.decoded.fee, v.name)
            XCTAssertEqual(String(envelope.transaction.sequence), v.decoded.seq, v.name)
            XCTAssertEqual(envelope.transaction.timeBounds?.maxTime ?? 0, v.decoded.maxTime, v.name)
            XCTAssertEqual(envelope.transaction.operations.map(\.body.typeName), v.decoded.ops, v.name)
            // Re-encoding is byte-exact.
            XCTAssertEqual(envelope.base64(), v.envelope, v.name)

            let pinned = PinnedContracts(network: .testnet, sponsor: v.sponsor, launchTokenWasmHash: "", roles: ["all": v.allowed])
            let verifier = TxVerifier(user: v.user, pinned: pinned, now: { Date(timeIntervalSince1970: v.now) })
            do {
                let outflow = try verifier.verify(envelope, intent: v.intent)
                XCTAssertTrue(v.expect.ok, "\(v.name): Swift accepted, server refused: \(v.expect.reason ?? "")")
                XCTAssertEqual(outflow.mapValues(String.init), v.expect.outflow ?? [:], v.name)
            } catch let f as VerificationFailure {
                XCTAssertFalse(v.expect.ok, "\(v.name): Swift refused (\(f.reason)), server accepted")
                if let reason = v.expect.reason {
                    let key = String(reason.lowercased().prefix(24))
                    XCTAssertTrue(f.reason.lowercased().contains(key), "\(v.name): '\(f.reason)' vs '\(reason)'")
                }
            }
            compared += 1
        }
        XCTAssertGreaterThan(compared, 30)
    }

    func testSigningAddsAVerifiableSignature() throws {
        let vectors: [VerifierVector] = try loadVectors("verifier")
        let v = try XCTUnwrap(vectors.first { $0.name == "payment ok" })
        var envelope = try TransactionEnvelope(base64: v.envelope)
        let signer = try StellarSigner(secret: "SBGWSG6BTNCKCOB3DIFBGCVMUPQFYPA2G4O34RMTB343OYPXU5DJDVMN")
        XCTAssertEqual(signer.address, v.user)
        XCTAssertFalse(envelope.isSigned(by: v.user, network: .testnet))
        try envelope.sign(with: signer, network: .testnet)
        XCTAssertTrue(envelope.isSigned(by: v.user, network: .testnet))
        XCTAssertFalse(envelope.isSigned(by: v.user, network: .mainnet))
        let reparsed = try TransactionEnvelope(base64: envelope.base64())
        XCTAssertEqual(reparsed.signatures.count, 1)
    }
}
