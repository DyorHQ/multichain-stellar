import XCTest
@testable import StellarCore

/// A swap the earlier TxVerifier accepted with an outflow of only its 100 XLM: routed through a token nobody lists, with
/// a Blend withdrawal to a third party nested under the swap's own authorization and an extra root handing the user's
/// launch's creator fees to that third party. Every part of it is now refused on its own; the shared vectors
/// (testCoversTheBindingCases) hold each shape separately, judged by both verifiers.
final class AuthorizationTreeTests: XCTestCase {
    private let user = "GDVEU3DD4KOFECV66VIHWEZOYX4ZKR3WV27L464SIIPOU2IUI3JCZA57"
    private let xlm = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
    private let usdc = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA"
    private let router = "CCJUD55AG6W5HAI5LRVNKAE5WDP5XGZBUDS5WNTIVDU7O264UZZE7BRD"
    private let blend = "CCEBVDYM32YNYCVNRXQKDFFPISJJCV557CDZEIRBEE4NCV4KHPQ44HGF"
    private let pad = "CAEEBNR6DDXCRCHBDUGPG5AWND5L2PHHEK4A77PDPHR4MTS5XVFRTMPS"
    /// Path [XLM, 0x66…66, USDC]; auth [swap → (XLM.transfer(user, router, 100), blend.submit(user, user, attacker, [])),
    /// launchpadV2.transfer_creator_fee_recipient(launch, attacker)].
    private let envelope = "AAAAAgAAAADqSmxj4pxSCr71UHsTLsX5lUd2rr6+e5JCHuppFEbSLAAAAGQAAAAAAAAAKgAAAAEAAAAAAAAAAAAAAABrSdMsAAAAAAAAAAEAAAAAAAAAGAAAAAAAAAABk0H3oDet04EdXGrVAJ2w39ubIaDl2zZoqOn3a9ymck8AAAAcc3dhcF9leGFjdF90b2tlbnNfZm9yX3Rva2VucwAAAAUAAAAKAAAAAAAAAAAAAAAAAAAAZAAAAAoAAAAAAAAAAAAAAAAAAAABAAAAEAAAAAEAAAADAAAAEgAAAAHXkotywnA8z+r365/0701QSlWouXn8m0UOoshCtNHOYQAAABIAAAABZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmYAAAASAAAAAVBFzV7Acpp2j9WtAlBYUt9PAo3Ogw5axSIJukhIOy8BAAAAEgAAAAAAAAAA6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iwAAAAFAAAAAAAAAAkAAAACAAAAAAAAAAAAAAABk0H3oDet04EdXGrVAJ2w39ubIaDl2zZoqOn3a9ymck8AAAAcc3dhcF9leGFjdF90b2tlbnNfZm9yX3Rva2VucwAAAAUAAAAKAAAAAAAAAAAAAAAAAAAAZAAAAAoAAAAAAAAAAAAAAAAAAAABAAAAEAAAAAEAAAADAAAAEgAAAAHXkotywnA8z+r365/0701QSlWouXn8m0UOoshCtNHOYQAAABIAAAABZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmYAAAASAAAAAVBFzV7Acpp2j9WtAlBYUt9PAo3Ogw5axSIJukhIOy8BAAAAEgAAAAAAAAAA6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iwAAAAFAAAAAAAAAAkAAAACAAAAAAAAAAHXkotywnA8z+r365/0701QSlWouXn8m0UOoshCtNHOYQAAAAh0cmFuc2ZlcgAAAAMAAAASAAAAAAAAAADqSmxj4pxSCr71UHsTLsX5lUd2rr6+e5JCHuppFEbSLAAAABIAAAABk0H3oDet04EdXGrVAJ2w39ubIaDl2zZoqOn3a9ymck8AAAAKAAAAAAAAAAAAAAAAAAAAZAAAAAAAAAAAAAAAAYgajwzesNwKrY3goZSvRJKRV734h5IiISE40VeKO+HOAAAABnN1Ym1pdAAAAAAABAAAABIAAAAAAAAAAOpKbGPinFIKvvVQexMuxfmVR3auvr57kkIe6mkURtIsAAAAEgAAAAAAAAAA6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iwAAAASAAAAAAAAAAD9FyQ4WqDHW2T7eM1gL6HZkf3r92sTxY7XAurINen2GAAAABAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAEIQLY+GO4oiOEdDPN0Fmj6vTznIrgP/eN548ZOXb1LGQAAAB50cmFuc2Zlcl9jcmVhdG9yX2ZlZV9yZWNpcGllbnQAAAAAAAIAAAASAAAAASIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiAAAAEgAAAAAAAAAA/RckOFqgx1tk+3jNYC+h2ZH96/drE8WO1wLqyDXp9hgAAAAAAAAAAAAAAAA="

    private func verifier() -> TxVerifier {
        let pinned = PinnedContracts(network: .testnet, sponsor: "GCLISPGBIWUJWHLGA2A55XYURSDSKH26HQNVBAOFPHXMB3ITONIAWZVS", launchTokenWasmHash: "",
                                     roles: ["all": [router, xlm, usdc, blend, pad]])
        return TxVerifier(user: user, pinned: pinned, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private var intent: Intent {
        Intent(kind: "swap", summary: "Swap 100 XLM for USDC", spend: [xlm: "100"], receive: [usdc: "1"],
               calls: [.init(contract: router, fn: "swap_exact_tokens_for_tokens")])
    }

    private func reason(_ intent: Intent, _ base64: String? = nil) throws -> String? {
        do {
            try verifier().verify(try TransactionEnvelope(base64: base64 ?? envelope), intent: intent)
            return nil
        } catch let f as VerificationFailure {
            return f.reason
        }
    }

    func testTheSmuggledSwapIsRefused() throws {
        XCTAssertEqual(try reason(intent), "The swap route goes through a token this app doesn't list.")
    }

    /// The same authorizations on a swap whose route is listed: the nested withdrawal is refused first, and without it
    /// the extra root.
    func testTheSmuggledAuthorizationsAreRefusedOnAListedRoute() throws {
        var env = try TransactionEnvelope(base64: envelope)
        guard case let .invokeHostFunction(.invokeContract(call), auth) = env.transaction.operations[0].body else { return XCTFail("no call") }
        // The path's middle token, as the call's XDR holds it (an SCAddress of 32 0x66 bytes), becomes USDC's.
        let evil = [UInt8](repeating: 0x66, count: 32)
        let usdcBytes = try StrKey.decode(.contract, usdc)
        let listed = Self.replacing(evil, with: usdcBytes, in: env.base64Bytes())
        env = try TransactionEnvelope(base64: Data(listed).base64EncodedString())
        XCTAssertEqual(try reason(intent, env.base64()), "The transaction asks you to authorize a call that is not a spend of your tokens.")
        XCTAssertEqual(auth.count, 2)
        XCTAssertEqual(call.function, "swap_exact_tokens_for_tokens")
    }

    private static func replacing(_ old: [UInt8], with new: [UInt8], in bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        var i = 0
        while i + old.count <= out.count {
            if Array(out[i..<(i + old.count)]) == old {
                out.replaceSubrange(i..<(i + old.count), with: new)
                i += new.count
            } else {
                i += 1
            }
        }
        return out
    }
}

private extension TransactionEnvelope {
    func base64Bytes() -> [UInt8] { [UInt8](Data(base64Encoded: base64()) ?? Data()) }
}

/// The runtime-contract check (RuntimeProvenance) agrees with the server's (verify.ts runtimeWasmHashOf) on the shared
/// vectors: an instance of a pinned v2 runtime WASM counts only when the pinned singleton created it, and only as the
/// contract asked for.
final class RuntimeProvenanceTests: XCTestCase {
    struct Vector: Decodable {
        struct Pins: Decodable {
            let launchpadV2: String
            let momentsV2: String
            let runtimeWasmHashes: [String: String]
            let launchTokenWasmHash: String
        }
        let name: String
        let entry: String
        let contract: String
        let pins: Pins
        let expect: String?
    }

    func testAgreesWithTheServer() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "runtime", withExtension: "json", subdirectory: "Vectors"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(vectors.count, 10)
        for v in vectors {
            let pinned = PinnedContracts(
                network: .testnet, sponsor: "GCLISPGBIWUJWHLGA2A55XYURSDSKH26HQNVBAOFPHXMB3ITONIAWZVS", launchTokenWasmHash: v.pins.launchTokenWasmHash,
                roles: ["launchpadV2": [v.pins.launchpadV2], "momentsV2": [v.pins.momentsV2]], runtimeWasmHashes: v.pins.runtimeWasmHashes
            )
            let bytes = try XCTUnwrap(Data(base64Encoded: v.entry), v.name)
            XCTAssertEqual(try RuntimeProvenance.wasmHash(ofInstance: [UInt8](bytes), contract: v.contract, pinned: pinned), v.expect, v.name)
        }
        let byName = Dictionary(vectors.map { ($0.name, $0.expect) }, uniquingKeysWith: { a, _ in a })
        for name in ["launch token created by another launchpad", "moment coin minted by the launchpad", "entry of another contract than the one asked for"] {
            XCTAssertEqual(byName[name] ?? "missing", nil, name)
        }
    }
}
