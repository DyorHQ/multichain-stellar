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
    /// v2's pins as the vector carries them (gen-vectors.ts VectorV2).
    struct V2: Decodable {
        struct Contracts: Decodable {
            let launchpadV2: String
            let momentsV2: String
            let lpLocker: String
            let execSoroswap: String
            let execAquarius: String?
            let momentsGraduator: String
        }
        struct Durations: Decodable { let launch: [String: UInt64]; let moments: [String: UInt64] }
        let contracts: Contracts
        let runtimeWasmHashes: [String: String]
        let durations: Durations
        let maxLaunchFeeStroops: String
    }
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
    let v2: V2?
    let runtime: [String: String]?
    let now: Double
    let step: Step?
    let expect: Expect
    let decoded: Decoded

    /// The pins the vector was judged with: its contracts, and v2's roles, runtime WASM hashes, durations and launch-fee
    /// bound as gen-pinned.ts writes them into PinnedContracts. `withV2: false` leaves v2 unpinned.
    func pinned(withV2: Bool = true) throws -> PinnedContracts {
        let fees = FeePolicy(maxFee: Int64(feePolicy.maxFee)!, maxInclusionFeePerOp: Int64(feePolicy.maxInclusionPerOp)!, starterInnerFeeMax: Int64(feePolicy.starterInnerFeeMax)!)
        var roles = ["all": allowed]
        guard withV2, let v2 else {
            return PinnedContracts(network: .testnet, sponsor: sponsor, launchTokenWasmHash: launchTokenWasmHash, roles: roles, feePolicy: fees, monadDomain: monadDomain)
        }
        let c = v2.contracts
        roles["launchpadV2"] = [c.launchpadV2]
        roles["momentsV2"] = [c.momentsV2]
        roles["lpLocker"] = [c.lpLocker]
        roles["execSoroswap"] = [c.execSoroswap]
        roles["momentsGraduator"] = [c.momentsGraduator]
        if let aquarius = c.execAquarius { roles["execAquarius"] = [aquarius] }
        func secs(_ set: [String: UInt64], _ name: String) throws -> UInt64 { try XCTUnwrap(set[name], "\(self.name): durations.\(name)") }
        let l = v2.durations.launch, m = v2.durations.moments
        let durations = PinnedDurations(
            launch: .init(
                grace: try secs(l, "grace"), fallbackDelay: try secs(l, "fallback_delay"), rescueAdmin: try secs(l, "rescue_admin"),
                rescuePublic: try secs(l, "rescue_public"), lockedFallback: try secs(l, "locked_fallback"),
                takeoverDelay: try secs(l, "takeover_delay"), takeoverWindow: try secs(l, "takeover_window"), timelock: try secs(l, "timelock"),
                timelockWindow: try secs(l, "timelock_window"), harvestInterval: try secs(l, "harvest_interval")
            ),
            moments: .init(
                vestPeriod: try secs(m, "vest_period"), stuckExpiry: try secs(m, "stuck_expiry"), pendingBackstop: try secs(m, "pending_backstop"),
                timelock: try secs(m, "timelock"), timelockWindow: try secs(m, "timelock_window"), minWindow: try secs(m, "min_window"),
                maxWindow: try secs(m, "max_window"), harvestInterval: try secs(m, "harvest_interval")
            )
        )
        return PinnedContracts(
            network: .testnet, sponsor: sponsor, launchTokenWasmHash: launchTokenWasmHash, roles: roles, feePolicy: fees, monadDomain: monadDomain,
            runtimeWasmHashes: v2.runtimeWasmHashes, durations: durations, maxLaunchFeeStroops: try XCTUnwrap(Int64(v2.maxLaunchFeeStroops))
        )
    }

    func verifier(withV2: Bool = true) throws -> TxVerifier {
        TxVerifier(user: user, pinned: try pinned(withV2: withV2), verifiedLaunchTokens: Set(launchTokens), runtimeContracts: runtime ?? [:], now: { Date(timeIntervalSince1970: now) })
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

            let verifier = try v.verifier()
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

    /// So are v2's bindings (DESIGN-stellar-contracts-v2 §20.4; verify.test.ts keeps the same list, with their verdicts).
    func testCoversTheV2Cases() throws {
        let vectors: [VerifierVector] = try loadVectors("verifier")
        let byName = Dictionary(vectors.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for name in [
            "v2 launch fee to the treasury", "v2 launch fee to another address than the launchpad", "v2 launch fee other than the terms",
            "v2 launch fee above the pinned bound", "v2 launch terms with an unpinned executor", "v2 launch terms with durations other than the pins",
            "v2 launch terms with the qa-exec-fail venue on the testnet pins", "v2 refund for another holder", "v2 moments collect from another account",
            "v2 claim rewards for another account", "v2 claim owed for another account", "v2 claim rewards from an unknown runtime WASM",
            "v2 graduate with your authorization", "v2 launch with a ticker that is not letters or digits",
            "v2 moments claim with a spend", "v2 moments claim all with a spend", "v2 moments publish with another locker",
            "v2 moments publish with another coin WASM", "v2 restore of an unknown runtime WASM's code",
        ] {
            XCTAssertEqual(byName[name]?.expect.ok, false, name)
        }
        for name in ["v2 launch create ok", "v2 launch create with an initial buy ok", "v2 refund ok", "v2 moments collect ok", "v2 claim rewards ok", "v2 moments publish ok"] {
            XCTAssertEqual(byName[name]?.expect.ok, true, name)
        }
        // Every v2 vector decodes, so the Swift verifier judges each one by its rules, not by a decoding error.
        for v in vectors where v.name.hasPrefix("v2 ") {
            XCTAssertNoThrow(try TransactionEnvelope(base64: v.envelope), v.name)
        }
        // The testnet pins: 10 XLM, and the launchpad's own pinned executor only.
        let pinned = try XCTUnwrap(byName["v2 launch create ok"]).pinned()
        XCTAssertEqual(pinned.maxLaunchFeeStroops, 100_000_000)
        XCTAssertEqual(TxVerifier.V2Pins(pinned)?.executors.count, 1)
    }

    /// The app's testnet pins are the owner's v2 deployment (deployments/testnet-v2.json, gen-pinned.ts): its
    /// singletons, the WASMs of the contracts it creates, production durations and the 10 XLM bound (verify.test.ts
    /// checks the server's).
    func testTestnetPinsTheOwnersV2Deployment() throws {
        let v2 = try XCTUnwrap(TxVerifier.V2Pins(.testnet))
        XCTAssertEqual(v2.launchpad, "CAEEBNR6DDXCRCHBDUGPG5AWND5L2PHHEK4A77PDPHR4MTS5XVFRTMPS")
        XCTAssertEqual(v2.moments, "CDABBNTQD2IOJMAFH75MKP4OKZJSGTFILZUBG4X5VSL4LMOX3HLPDOQL")
        XCTAssertEqual(v2.locker, "CDIZ4NTKKCEETUL6RUPHCI35IRHAB7RKB5EOZFGHN7ZFPBXPCNCCWDMP")
        XCTAssertEqual(v2.graduator, "CB7MBSRVNSQCTLG35NDX7B2XUOYRZMVFB6Q32ANANZQLNEGJFKLW2VIA")
        XCTAssertEqual(v2.soroswapExecutor, "CA7RDHGNXATQNQSIPA5P7U36NY33OPMLWICI4FFWXPYXZIWTAEBHV5BF")
        // Soroswap only (O7): no Aquarius executor, and never testnet-qa's failing venue (F4).
        XCTAssertEqual(v2.executors, ["CA7RDHGNXATQNQSIPA5P7U36NY33OPMLWICI4FFWXPYXZIWTAEBHV5BF"])
        XCTAssertEqual(v2.launchTokenWasm, "f09bc5743aaf94626d04f5831759abf7ed9d03fa42f3ac791b7d9d747a256707")
        XCTAssertEqual(v2.nftWasm, "e14e1676a4071b6e5f3bdf7335250fb6439251e3ffd11d12db5815bd1207a2c9")
        XCTAssertEqual(v2.coinWasm, "9106f6a8a0513bedec4ec33f6a200acadcf0f2f79b6158609b71c1cdf3dc6e2a")
        XCTAssertEqual(v2.durations.launch.grace, 3_600)
        XCTAssertEqual(v2.durations.launch.fallbackDelay, 3_600)
        XCTAssertEqual(v2.durations.launch.rescuePublic, 2_592_000)
        XCTAssertEqual(v2.durations.launch.harvestInterval, 3_600)
        XCTAssertEqual(v2.durations.moments.vestPeriod, 2_592_000)
        XCTAssertEqual(v2.durations.moments.pendingBackstop, 2_592_000)
        XCTAssertEqual(v2.maxLaunchFeeStroops, 100_000_000)
        // Every v2 singleton is on the allowlist; the runtime contracts are allowed by these hashes only.
        for role in ["launchpadV2", "momentsV2", "lpLocker", "execSoroswap", "momentsGraduator"] {
            XCTAssertEqual(PinnedContracts.testnet.contracts(role).count, 1, role)
        }
        XCTAssertTrue(PinnedContracts.testnet.contracts("execAquarius").isEmpty)
    }

    /// Without v2's pins, a call is judged by v1's rules and a runtime contract's hash allows nothing (verify.test.ts
    /// checks the same two).
    func testWithoutV2PinsTheV1RulesApply() throws {
        let vectors: [VerifierVector] = try loadVectors("verifier")
        let launch = try XCTUnwrap(vectors.first { $0.name == "v2 launch create ok" })
        XCTAssertThrowsError(try launch.verifier(withV2: false).verify(try TransactionEnvelope(base64: launch.envelope), intent: launch.intent)) {
            XCTAssertEqual(($0 as? VerificationFailure)?.reason, "The call's arguments are not as expected.")
        }
        let rewards = try XCTUnwrap(vectors.first { $0.name == "v2 claim rewards ok" })
        let token = try XCTUnwrap(rewards.runtime?.keys.first)
        XCTAssertThrowsError(try rewards.verifier(withV2: false).verify(try TransactionEnvelope(base64: rewards.envelope), intent: rewards.intent)) {
            XCTAssertEqual(($0 as? VerificationFailure)?.reason, "Contract \(token) is not on the allowlist.")
        }
        // Pins without v2's roles have no v2 pins.
        XCTAssertNil(TxVerifier.V2Pins(try launch.pinned(withV2: false)))
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

    /// So are the authorization tree, swap routes, minimums and what the user typed into a v2 launch or Moment
    /// (verify.test.ts keeps the same list, BINDING_CASES): each with its verdict and reason.
    func testCoversTheBindingCases() throws {
        let vectors: [VerifierVector] = try loadVectors("verifier")
        let byName = Dictionary(vectors.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let cases: [(String, String?)] = [
            ("swap with a non-token call nested under its own authorization", "The transaction asks you to authorize a call that is not a spend of your tokens."),
            ("swap with a non-token call nested under a token spend", "The transaction asks you to authorize a call that is not a spend of your tokens."),
            ("swap with a nested spend of another account's tokens", "The transaction asks you to authorize a call that is not a spend of your tokens."),
            ("swap with a nested spend with extra arguments", "The transaction asks you to authorize a call that is not a spend of your tokens."),
            ("blend submit with a nested withdrawal", "The transaction asks you to authorize a call that is not a spend of your tokens."),
            ("v2 launch with a non-token call nested under its own authorization", "The transaction asks you to authorize a call that is not a spend of your tokens."),
            ("swap with a second root authorizing another call", "The transaction asks you to authorize a call other than this one."),
            ("swap with a second root transferring to the confirmed address", "The transaction asks you to authorize a call other than this one."),
            ("transfer in another root to another account", "The transaction asks you to authorize a call other than this one."),
            ("v2 curve buy with a creator-fee recipient change as a second root", "The transaction asks you to authorize a call other than this one."),
            ("v2 claim rewards with a second root", "The transaction asks you to authorize a call other than this one."),
            ("soroswap through an unlisted middle token", "The swap route goes through a token this app doesn't list."),
            ("soroswap to an unlisted token the intent doesn't quote", "The swap route goes through a token this app doesn't list."),
            ("aquarius through an unlisted hop token", "The swap route goes through a token this app doesn't list."),
            ("soroswap through a listed middle token ok", nil),
            ("soroswap to an unlisted token the intent quotes ok", nil),
            ("soroswap from an unlisted token the intent spends ok", nil),
            ("aquarius through listed hops ok", nil),
            ("soroswap with no minimum", "The transaction sets no minimum received."),
            ("aquarius with no minimum", "The transaction sets no minimum received."),
            ("curve buy with no minimum", "The transaction sets no minimum received."),
            ("curve sell with no minimum", "The transaction sets no minimum received."),
            ("v2 launch initial buy with no minimum", "The transaction sets no minimum received."),
            ("path payment without a quoted minimum", "The minimum received is lower than quoted."),
            ("v2 launch creator fees to a third party", "The creator fees go to another address than the one you confirmed."),
            ("v2 launch creator fees to another than the confirmed recipient", "The creator fees go to another address than the one you confirmed."),
            ("v2 launch creator fees to the user when a recipient was confirmed", "The creator fees go to another address than the one you confirmed."),
            ("v2 launch showing another recipient", "The creator fees go to another address than the one you confirmed."),
            ("v2 launch without its settings shown", "The creator fees go to another address than the one you confirmed."),
            ("v2 launch with a snipe exemption not shown", "The launch settings are not the ones shown."),
            ("v2 launch with snipe exemptions in another order", "The launch settings are not the ones shown."),
            ("v2 launch with another creator fee", "The launch settings are not the ones shown."),
            ("v2 launch with holder sharing other than shown", "The launch settings are not the ones shown."),
            ("v2 launch creator fees to the user named ok", nil),
            ("v2 launch creator fees to the confirmed recipient ok", nil),
            ("v2 launch with its snipe exemptions shown ok", nil),
            ("v2 moments publish at another price", "The Moment's price, allocation or window is not the one shown."),
            ("v2 moments publish with another allocation", "The Moment's price, allocation or window is not the one shown."),
            ("v2 moments publish with another window", "The Moment's price, allocation or window is not the one shown."),
            ("v2 moments publish without its settings shown", "The Moment's price, allocation or window is not the one shown."),
        ]
        for (name, reason) in cases {
            let v = try XCTUnwrap(byName[name], name)
            XCTAssertEqual(v.expect.ok, reason == nil, name)
            if let reason { XCTAssertEqual(v.expect.reason.map(swiftReason), reason, name) }
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
