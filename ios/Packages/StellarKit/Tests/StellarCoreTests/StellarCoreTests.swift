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
    struct StepVerdict: Decodable { let ok: Bool; let payer: String?; let reason: String? }
    struct Expect: Decodable { let ok: Bool; let reason: String?; let outflow: [String: String]?; let step: StepVerdict? }
    struct Memo: Decodable, Equatable { let type: String; let value: String }
    struct Decoded: Decodable {
        let source: String
        let fee: UInt32
        let seq: String
        let maxTime: UInt64
        let ops: [String]
        let resourceFee: String?
        let memo: Memo?
        let to: String?
    }
    struct Fees: Decodable { let maxFee: String; let maxInclusionPerOp: String; let starterInnerFeeMax: String }
    struct Step: Decodable { let feePayer: String?; let sponsorReason: String? }
    let name: String
    let envelope: String
    let intent: Intent
    let user: String
    let sponsor: String
    let allowed: [String]
    let launchTokens: [String]
    let launchTokenWasmHash: String
    let monadDomain: UInt32
    let feePolicy: Fees
    let now: Double
    let step: Step?
    let expect: Expect
    let decoded: Decoded

    var pinned: PinnedContracts {
        let fees = FeePolicy(maxFee: Int64(feePolicy.maxFee)!, maxInclusionFeePerOp: Int64(feePolicy.maxInclusionPerOp)!, starterInnerFeeMax: Int64(feePolicy.starterInnerFeeMax)!)
        return PinnedContracts(network: .testnet, sponsor: sponsor, launchTokenWasmHash: launchTokenWasmHash, roles: ["all": allowed], feePolicy: fees, monadDomain: monadDomain)
    }
}

/// The TS verifier's reason as the Swift verifier words it: a capital letter and a full stop.
private func swiftReason(_ reason: String) -> String {
    reason.prefix(1).uppercased() + reason.dropFirst() + "."
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

final class XDRTests: XCTestCase {
    private func xdr(_ bytes: [UInt8]) -> XDRReader {
        var w = XDRWriter()
        w.variable(bytes)
        return XDRReader(w.bytes)
    }

    func testStringsAreReadByteForByte() throws {
        let marked: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("transfer".utf8)
        var r = xdr(marked)
        let name = try r.string(max: 32)
        XCTAssertEqual(Array(name.utf8), marked, "the byte-order mark is kept")
        XCTAssertNotEqual(name, "transfer")
        var invalid = xdr([0x61, 0xFF])
        XCTAssertThrowsError(try invalid.string(max: 32)) { XCTAssertEqual($0 as? XDRError, .invalid("string")) }
    }

    func testPaddingIsZeros() throws {
        var zeros = XDRReader([0, 0, 0, 1, 0x61, 0, 0, 0])
        XCTAssertEqual(try zeros.variable(max: 4), [0x61])
        var other = XDRReader([0, 0, 0, 1, 0x61, 0, 0, 1])
        XCTAssertThrowsError(try other.variable(max: 4)) { XCTAssertEqual($0 as? XDRError, .invalid("padding")) }
    }

    func testValuesAndCallsAreTheSameOnlyByteForByte() throws {
        // Swift's == on text calls the two spellings of "Café" equal; their XDR differs, and so do the values.
        let nfc = "Caf\u{E9}", nfd = "Cafe\u{301}"
        XCTAssertNotEqual(SCVal.string(nfc), SCVal.string(nfd))
        XCTAssertNotEqual(SCVal.symbol(nfc), SCVal.symbol(nfd))
        XCTAssertNotEqual(SCVal.error(type: 0, code: 1), SCVal.error(type: 0, code: 2))
        XCTAssertEqual(SCVal.error(type: 0, code: 1), SCVal.error(type: 0, code: 1))
        // A call to `launch` with one string argument, decoded.
        func call(_ text: String) throws -> InvokeContractArgs {
            var w = XDRWriter()
            w.uint32(1) // SC_ADDRESS_TYPE_CONTRACT
            w.raw([UInt8](repeating: 0x22, count: 32))
            w.variable(Array("launch".utf8))
            w.uint32(1) // one argument
            w.uint32(14) // SCV_STRING
            w.variable(Array(text.utf8))
            var r = XDRReader(w.bytes)
            return try XDRDecode.invokeContractArgs(&r)
        }
        XCTAssertEqual(try call(nfc), try call(nfc))
        XCTAssertNotEqual(try call(nfc), try call(nfd))
    }
}

final class AmountTests: XCTestCase {
    func testParseAndFormat() {
        XCTAssertEqual(StellarAmount.parse("12.5"), 125_000_000)
        XCTAssertEqual(StellarAmount.parse("0.0000001"), 1)
        XCTAssertEqual(StellarAmount.parse("1.123456789"), 11_234_567)
        XCTAssertNil(StellarAmount.parse("1.2.3"))
        XCTAssertNil(StellarAmount.parse("-1"))
        XCTAssertNil(StellarAmount.parse(""))
        XCTAssertEqual(StellarAmount.format(Int64(125_000_000)), "12.5")
        XCTAssertEqual(StellarAmount.format(Int64(1)), "0.0000001")
    }
}

final class VerifierVectorTests: XCTestCase {
    /// Every vector the TypeScript verifier judged: the Swift verifier must reach the same verdict, for the same reason,
    /// with the same outflow, and say the same about who pays.
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
            let tx = envelope.transaction
            XCTAssertEqual(tx.source, v.decoded.source, v.name)
            XCTAssertEqual(tx.fee, v.decoded.fee, v.name)
            XCTAssertEqual(String(tx.sequence), v.decoded.seq, v.name)
            XCTAssertEqual(tx.timeBounds?.maxTime ?? 0, v.decoded.maxTime, v.name)
            XCTAssertEqual(tx.operations.map(\.body.typeName), v.decoded.ops, v.name)
            XCTAssertEqual(tx.resourceFee.map(String.init), v.decoded.resourceFee, v.name)
            XCTAssertEqual(Self.memo(tx.memo), v.decoded.memo, v.name)
            XCTAssertEqual(Self.destination(tx), v.decoded.to, v.name)
            // Re-encoding is byte-exact.
            XCTAssertEqual(envelope.base64(), v.envelope, v.name)

            let verifier = TxVerifier(user: v.user, pinned: v.pinned, verifiedLaunchTokens: Set(v.launchTokens), now: { Date(timeIntervalSince1970: v.now) })
            do {
                let outflow = try verifier.verify(envelope, intent: v.intent)
                XCTAssertTrue(v.expect.ok, "\(v.name): Swift accepted, server refused: \(v.expect.reason ?? "")")
                XCTAssertEqual(outflow.mapValues(String.init), v.expect.outflow ?? [:], v.name)
            } catch let f as VerificationFailure {
                XCTAssertFalse(v.expect.ok, "\(v.name): Swift refused (\(f.reason)), server accepted")
                XCTAssertEqual(f.reason, v.expect.reason.map(swiftReason), v.name)
            }
            if let step = v.step {
                let verdict = try XCTUnwrap(v.expect.step, v.name)
                do {
                    let payer = try verifier.feePayer(envelope, intent: v.intent, flaggedPayer: step.feePayer, sponsorReason: step.sponsorReason)
                    XCTAssertTrue(verdict.ok, "\(v.name): Swift found a payer, server refused: \(verdict.reason ?? "")")
                    XCTAssertEqual(Self.payerName(payer), verdict.payer, v.name)
                } catch let f as VerificationFailure {
                    XCTAssertFalse(verdict.ok, "\(v.name): Swift refused the payer (\(f.reason)), server accepted")
                    XCTAssertEqual(f.reason, verdict.reason.map(swiftReason), v.name)
                }
            }
            compared += 1
        }
        XCTAssertGreaterThan(compared, 30)
    }

    /// The design's list of cases (§12.4) is in the vectors, so dropping one fails here as well as in Deno.
    func testCoversTheDesignsCases() throws {
        let vectors: [VerifierVector] = try loadVectors("verifier")
        let names = Set(vectors.map(\.name))
        for name in [
            "classic fee at the cap ok", "inclusion over the cap", "soroban fee over the cap", "resource fee above fee",
            "activate ok", "activate funds XLM", "user-paid trust ok", "sponsor outside activation",
            "payment to another destination", "memo mismatch", "SAC transfer to another to", "soroswap to another account",
            "soroswap min below receive", "curve buy min_tokens_out below receive", "blend submit to another account",
            "cctp burn to another mint recipient", "restore with a footprint outside the allowlist", "restore ok",
            "starter step with an inner fee above the cap",
        ] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    /// So are the cases where a decoder or a comparison could tell the two verifiers apart (verify.test.ts keeps the
    /// same list, with their verdicts).
    func testCoversTheParityCases() throws {
        let vectors: [VerifierVector] = try loadVectors("verifier")
        let names = Set(vectors.map(\.name))
        for name in [
            "auth root that is the call in another normalization", "auth root that is the call with another error code",
            "call to a function name with a byte-order mark", "trust removed", "trust with a negative limit",
            "soroban swap with a footprint ok",
        ] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    private static func memo(_ memo: StellarMemo) -> VerifierVector.Memo? {
        switch memo {
        case .none: return nil
        case let .text(bytes): return .init(type: "text", value: String(decoding: bytes, as: UTF8.self))
        case let .id(id): return .init(type: "id", value: String(id))
        case let .hash(bytes): return .init(type: "hash", value: bytes.map { String(format: "%02x", $0) }.joined())
        case let .returnHash(bytes): return .init(type: "return", value: bytes.map { String(format: "%02x", $0) }.joined())
        }
    }

    /// The first operation's destination, as gen-vectors.ts records it.
    private static func destination(_ tx: Transaction) -> String? {
        switch tx.operations.first?.body {
        case let .payment(destination, _, _)?, let .createAccount(destination, _)?: return destination
        case let .pathPaymentStrictSend(_, _, destination, _, _, _)?: return destination
        case let .invokeHostFunction(.invokeContract(call), _)?:
            return call.function == "transfer" && call.args.count > 1 ? call.args[1].addressString : nil
        default: return nil
        }
    }

    private static func payerName(_ payer: StellarFeePayer) -> String {
        switch payer {
        case .user: return "user"
        case let .dyorHQ(reason): return reason.rawValue
        }
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
