import CryptoKit
import XCTest
@testable import DyorKit

/// Perpl API-key enrollment validates the server's EIP-712 payload before anything is signed. `genuineJSON` is a
/// verbatim `typed_data` from `POST https://app.perpl.xyz/api/v1/api-key/payload` (2026-09-23) for a throwaway wallet
/// and a throwaway Ed25519 key, requested as the app does (chain 143, scope_mask 2, label "DyorHQ", no Origin); its
/// digest was cross-checked with eth_account `encode_typed_data` and viem `hashTypedData`.
final class PerplEnrollmentTests: XCTestCase {
    static let address = "0x59C70195a9f380b9358780cb862DDe2fEADc9755"
    static let publicKeyHex = "0xcbc39728e855f6e052bef590e2cd05f120324e13155c4ac3bac3b6ca58969b2c"
    /// `message.time` (0x1a0ced1983c ms).
    static let issuedAt = Date(timeIntervalSince1970: 1_790_176_237.628)
    static let referenceDigest = "0xa83c5947b71c1f2d7dbe8c9a78091442b87c1ea67c867729eaeeb7096297f295"

    static let genuineJSON = #"""
    {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"},{"name":"salt","type":"bytes32"}],"PerplRegisterApiKey":[{"name":"signer","type":"address"},{"name":"statement","type":"string"},{"name":"publicKey","type":"string"},{"name":"scope","type":"string"},{"name":"label","type":"string"},{"name":"expiresAt","type":"string"},{"name":"ipCidrs","type":"string"},{"name":"origin","type":"string"},{"name":"builderId","type":"string"},{"name":"maxBuilderFeePer100K","type":"string"},{"name":"time","type":"uint64"}]},"primaryType":"PerplRegisterApiKey","domain":{"name":"perpl.xyz","version":"1","chainId":"0x8f","verifyingContract":"0x0000000000000000000000000000000000000000","salt":"0x00000000000000000000000000000000000000006ab3ebed8efa1dc38d972851"},"message":{"builderId":"0","expiresAt":"0","ipCidrs":"","label":"DyorHQ","maxBuilderFeePer100K":"0","origin":"","publicKey":"y8OXKOhV9uBSvvWQ4s0F8SAyThMVXErDusO2yliWmyw","scope":"3","signer":"0x59C70195a9f380b9358780cb862DDe2fEADc9755","statement":"I authorize the creation of Perpl API key with the specified scope and parameters","time":"0x1a0ced1983c"}}
    """#

    private func genuine() -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(Self.genuineJSON.utf8)) as! [String: Any]
    }

    /// The genuine payload with one value in `section` ("domain" / "message" / "types") replaced (nil removes it).
    private func tampered(_ section: String, _ key: String, _ value: Any?) -> [String: Any] {
        var json = genuine()
        var inner = json[section] as! [String: Any]
        inner[key] = value
        json[section] = inner
        return json
    }

    @discardableResult
    private func validate(_ json: [String: Any], chainId: Int = 143, address: String = PerplEnrollmentTests.address,
                          publicKeyHex: String = PerplEnrollmentTests.publicKeyHex, scopeMask: Int = PerplScope.trade,
                          label: String = "DyorHQ", now: Date = PerplEnrollmentTests.issuedAt) throws -> PerplEnrollment.Validated {
        try PerplEnrollment.validate(json, chainId: chainId, address: address, publicKeyHex: publicKeyHex, scopeMask: scopeMask, label: label, now: now)
    }

    private func assertRejected(_ json: [String: Any], _ expected: PerplEnrollmentError, chainId: Int = 143,
                                address: String = PerplEnrollmentTests.address, publicKeyHex: String = PerplEnrollmentTests.publicKeyHex,
                                now: Date = PerplEnrollmentTests.issuedAt, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try validate(json, chainId: chainId, address: address, publicKeyHex: publicKeyHex, now: now), file: file, line: line) { error in
            XCTAssertEqual(error as? PerplEnrollmentError, expected, file: file, line: line)
        }
    }

    private static func randomPublicKeyHex() -> String { try! PerplAuth.publicKeyHex(secret: PerplAuth.newSecret()) }

    // MARK: Genuine shape

    func testGenuinePayloadValidatesToReferenceDigest() throws {
        let validated = try validate(genuine())
        XCTAssertEqual(validated.digest.hexString, Self.referenceDigest)
        // Same digest as the server's own structure, which is what Perpl verifies the wallet signature against.
        XCTAssertEqual(try EIP712.digest(EIP712.parse(genuine())), validated.digest)
        XCTAssertEqual(validated.typedData.primaryType, "PerplRegisterApiKey")
    }

    func testGenuineVariantsStillValidate() throws {
        try validate(genuine(), address: Self.address.lowercased())                // address case never matters
        try validate(tampered("message", "scope", "2"))                            // un-normalized trade scope
        try validate(tampered("domain", "chainId", 143))                           // chain id as a JSON number
        try validate(genuine(), now: Self.issuedAt.addingTimeInterval(10 * 60))    // within clock skew, either way
        try validate(genuine(), now: Self.issuedAt.addingTimeInterval(-10 * 60))
    }

    // MARK: Domain

    func testRejectsForeignChainId() {
        assertRejected(tampered("domain", "chainId", "0x1"), .wrongChain)
        assertRejected(tampered("domain", "chainId", "0x279f"), .wrongChain)       // 10143, testnet
        assertRejected(genuine(), .wrongChain, chainId: 1)                         // client not on Monad mainnet
    }

    func testRejectsForeignVerifyingContract() {
        assertRejected(tampered("domain", "verifyingContract", Perpl.exchange.hex), .wrongDomain("contract"))
        assertRejected(tampered("domain", "verifyingContract", "0x000000000022D473030F116dDEE9F6B43aC78BA3"), .wrongDomain("contract")) // Permit2
        assertRejected(tampered("domain", "verifyingContract", "0x0"), .wrongDomain("contract"))
        // Parse to the zero address through `Data(hex:)`, but are not the hex the genuine payload writes.
        assertRejected(tampered("domain", "verifyingContract", "0x" + String(repeating: "+0", count: 20)), .wrongDomain("contract"))
        assertRejected(tampered("domain", "verifyingContract", " " + Address.zero.hex), .wrongDomain("contract"))
    }

    func testRejectsForeignDomainNameVersionOrShape() {
        assertRejected(tampered("domain", "name", "Permit2"), .wrongDomain("name"))
        assertRejected(tampered("domain", "name", "perpl.xyz "), .wrongDomain("name"))
        assertRejected(tampered("domain", "version", "2"), .wrongDomain("version"))
        assertRejected(tampered("domain", "salt", "0x1234"), .wrongDomain("salt"))
        assertRejected(tampered("domain", "salt", "0x" + String(repeating: "+f", count: 32)), .wrongDomain("salt")) // signed pairs
        assertRejected(tampered("domain", "salt", "0X" + String(repeating: "ab", count: 32)), .wrongDomain("salt"))
        assertRejected(tampered("domain", "salt", nil), .wrongDomain("fields"))
        assertRejected(tampered("domain", "extra", "1"), .wrongDomain("fields"))
    }

    // MARK: Types

    func testRejectsPrimaryTypesOutsideTheAllowlist() {
        for primary in ["Permit", "PermitSingle", "PermitTransferFrom", "PermitBatch", "Order", "Transfer", "Approval", "EIP712Domain", "perplregisterapikey"] {
            var json = genuine()
            json["primaryType"] = primary
            assertRejected(json, .disallowedType)
        }
        var missing = genuine()
        missing["primaryType"] = nil
        assertRejected(missing, .unexpectedShape("typed data"))
    }

    func testRejectsChangedTypes() {
        let types = genuine()["types"] as! [String: Any]
        let original = types["PerplRegisterApiKey"] as! [[String: String]]

        let permitDetails = [["name": "token", "type": "address"], ["name": "amount", "type": "uint160"]]
        assertRejected(tampered("types", "PermitDetails", permitDetails), .wrongTypes)                  // an extra struct

        var retyped = original
        retyped[0] = ["name": "signer", "type": "string"]
        assertRejected(tampered("types", "PerplRegisterApiKey", retyped), .wrongTypes)                  // a field's type

        assertRejected(tampered("types", "PerplRegisterApiKey", original + [["name": "amount", "type": "uint256"]]), .wrongTypes) // extra field
        assertRejected(tampered("types", "PerplRegisterApiKey", Array(original.reversed())), .wrongTypes) // reordered
        assertRejected(tampered("types", "PerplRegisterApiKey", Array(original.dropLast())), .wrongTypes) // missing field

        var decorated = original.map { $0 as [String: Any] }
        decorated[0]["indexed"] = true
        assertRejected(tampered("types", "PerplRegisterApiKey", decorated), .wrongTypes)                // entry with an extra key

        let domainWithoutSalt = Array((types["EIP712Domain"] as! [[String: String]]).dropLast())
        assertRejected(tampered("types", "EIP712Domain", domainWithoutSalt), .wrongTypes)
    }

    // MARK: Binding

    func testRejectsForeignPublicKey() {
        // The server substitutes its own key for the one this device generated.
        let foreign = PerplAuth.base64url(Data(hex: Self.randomPublicKeyHex())!)
        assertRejected(tampered("message", "publicKey", foreign), .foreignKey)
        // Or the genuine payload is replayed against an enrollment with a different key.
        assertRejected(genuine(), .foreignKey, publicKeyHex: Self.randomPublicKeyHex())
        assertRejected(tampered("message", "publicKey", Self.publicKeyHex), .foreignKey)               // hex, not base64url
    }

    func testRejectsForeignAddress() {
        assertRejected(tampered("message", "signer", "0x000000000000000000000000000000000000dEaD"), .foreignSigner)
        assertRejected(tampered("message", "signer", "not an address"), .foreignSigner)
        assertRejected(genuine(), .foreignSigner, address: "0x1111111111111111111111111111111111111111")
        // Same 20 bytes through `Address`, but not the hex the genuine payload writes.
        assertRejected(tampered("message", "signer", " " + Self.address), .foreignSigner)
        assertRejected(tampered("message", "signer", "0x59C7+195a9f380b9358780cb862DDe2fEADc9755"), .foreignSigner)
    }

    // MARK: Terms

    func testRejectsExpiredOrFuturePayload() {
        assertRejected(genuine(), .stale, now: Self.issuedAt.addingTimeInterval(16 * 60))              // replayed / expired
        assertRejected(genuine(), .stale, now: Self.issuedAt.addingTimeInterval(-16 * 60))             // issued in the future
        assertRejected(genuine(), .stale, now: Self.issuedAt.addingTimeInterval(24 * 60 * 60))
        assertRejected(tampered("message", "time", "0x0"), .stale)
        assertRejected(tampered("message", "time", "soon"), .stale)
        assertRejected(tampered("message", "time", "0x1ffffffffffffffff"), .stale)                     // > uint64
    }

    func testRejectsChangedKeyTerms() {
        assertRejected(tampered("message", "expiresAt", "1790179837628"), .unexpectedTerms("expiry"))
        assertRejected(tampered("message", "ipCidrs", "203.0.113.0/24"), .unexpectedTerms("IP allow-list"))
        assertRejected(tampered("message", "origin", "https://evil.example"), .unexpectedTerms("origin"))
        assertRejected(tampered("message", "label", "Perpl"), .unexpectedTerms("label"))
        assertRejected(tampered("message", "statement", "I authorize the transfer of all my funds"), .unexpectedTerms("statement"))
    }

    func testRejectsBuilderFeeAndWiderScope() {
        assertRejected(tampered("message", "builderId", "7"), .builderFee)
        assertRejected(tampered("message", "maxBuilderFeePer100K", "100"), .builderFee)
        assertRejected(tampered("message", "scope", "7"), .wrongScope)
        assertRejected(tampered("message", "scope", "1"), .wrongScope)                                 // read-only is not what was asked
        assertRejected(tampered("message", "scope", "255"), .wrongScope)
    }

    // MARK: Shape

    func testRejectsExtraOrMissingFields() {
        assertRejected(tampered("message", "amount", "1000000"), .unexpectedShape("message fields"))
        assertRejected(tampered("message", "spender", Perpl.exchange.hex), .unexpectedShape("message fields"))
        assertRejected(tampered("message", "origin", nil), .unexpectedShape("message fields"))
        assertRejected(tampered("message", "label", 5), .unexpectedShape("message values"))
        var extraTop = genuine()
        extraTop["digest"] = Self.referenceDigest
        assertRejected(extraTop, .unexpectedShape("typed data"))
    }

    func testDigestBackstopCatchesWhatTheFieldChecksMiss() {
        // KELVIN SIGN (U+212A) is canonically equivalent to "K", so Swift's `==` passes the key check, but it is
        // different UTF-8, so the server's structure hashes to another message than the canonical rebuild.
        let lookalike = "y8OX\u{212A}OhV9uBSvvWQ4s0F8SAyThMVXErDusO2yliWmyw"
        let genuineKey = (genuine()["message"] as! [String: Any])["publicKey"] as! String
        XCTAssertEqual(lookalike, genuineKey)
        XCTAssertNotEqual(Array(lookalike.utf8), Array(genuineKey.utf8))
        assertRejected(tampered("message", "publicKey", lookalike), .digestMismatch)
    }

    func testErrorsAreUserFacingAndNeverEchoServerText() {
        let text = PerplEnrollmentError.foreignKey.errorDescription ?? ""
        XCTAssertTrue(text.contains("Nothing was signed"))
        XCTAssertTrue(text.contains("did not create"))
        // Reasons name the app's own fields only; nothing from the payload is interpolated.
        XCTAssertEqual(PerplEnrollmentError.unexpectedTerms("expiry").errorDescription,
                       "DyorHQ refused to sign Perpl's trading-key request because it changes the key's terms (expiry). Nothing was signed. Try again later.")
    }

    // MARK: Client (stubbed transport)

    private func client() -> PerplAuthClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PerplEnrollTransport.self]
        return PerplAuthClient(chainId: 143, apiBase: URL(string: "https://perpl.test/api")!, session: URLSession(configuration: configuration))
    }

    private func reply(typedData: [String: Any], extra: [String: Any] = [:]) -> Data {
        var body: [String: Any] = ["typed_data": typedData, "mac": "0x" + String(repeating: "ab", count: 32)]
        body.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    override func setUp() {
        super.setUp()
        PerplEnrollTransport.reset()
    }

    func testRequestPayloadSignsTheLocallyComputedDigest() async throws {
        PerplEnrollTransport.replies["/v1/api-key/payload"] = reply(typedData: genuine())
        let payload = try await client().requestPayload(address: Self.address, publicKeyHex: Self.publicKeyHex, scopeMask: PerplScope.trade, label: "DyorHQ", now: Self.issuedAt)
        XCTAssertEqual(payload.digest.hexString, Self.referenceDigest)
        let sent = try XCTUnwrap(PerplEnrollTransport.requests.first?.body)
        XCTAssertEqual(sent["chain_id"] as? Int, 143)
        XCTAssertEqual(sent["address"] as? String, Self.address)
        XCTAssertEqual(sent["public_key"] as? String, Self.publicKeyHex)
        XCTAssertEqual(sent["scope_mask"] as? Int, PerplScope.trade)
        XCTAssertNil(sent["builder_id"])
        XCTAssertNil(sent["expires_at"])
    }

    func testRequestPayloadRejectsAServerSuppliedDigestMismatch() async throws {
        // A digest that agrees with the typed data is ignored (the local one is what gets signed)…
        PerplEnrollTransport.replies["/v1/api-key/payload"] = reply(typedData: genuine(), extra: ["digest": Self.referenceDigest])
        let payload = try await client().requestPayload(address: Self.address, publicKeyHex: Self.publicKeyHex, scopeMask: PerplScope.trade, label: "DyorHQ", now: Self.issuedAt)
        XCTAssertEqual(payload.digest.hexString, Self.referenceDigest)

        // …one that names any other message is a request for a blind signature.
        for field in ["digest", "hash"] {
            PerplEnrollTransport.replies["/v1/api-key/payload"] = reply(typedData: genuine(), extra: [field: "0x" + String(repeating: "11", count: 32)])
            do {
                _ = try await client().requestPayload(address: Self.address, publicKeyHex: Self.publicKeyHex, scopeMask: PerplScope.trade, label: "DyorHQ", now: Self.issuedAt)
                XCTFail("a mismatched server digest must be refused")
            } catch {
                XCTAssertEqual(error as? PerplEnrollmentError, .digestMismatch)
            }
        }
    }

    func testRequestPayloadRejectsTamperedTypedDataBeforeReturningADigest() async {
        PerplEnrollTransport.replies["/v1/api-key/payload"] = reply(typedData: tampered("message", "publicKey", PerplAuth.base64url(Data(hex: Self.randomPublicKeyHex())!)))
        do {
            _ = try await client().requestPayload(address: Self.address, publicKeyHex: Self.publicKeyHex, scopeMask: PerplScope.trade, label: "DyorHQ", now: Self.issuedAt)
            XCTFail("a payload for a foreign key must be refused")
        } catch {
            XCTAssertEqual(error as? PerplEnrollmentError, .foreignKey)
        }
    }

    func testEnrollProvesPossessionOverTheValidatedDigestOnly() async throws {
        // A fresh key this "device" generated, and the genuine payload re-issued for it.
        let secret = PerplAuth.newSecret()
        let publicKeyHex = try PerplAuth.publicKeyHex(secret: secret)
        let publicKey = Data(hex: publicKeyHex)!
        let typedData = tampered("message", "publicKey", PerplAuth.base64url(publicKey))
        PerplEnrollTransport.replies["/v1/api-key/payload"] = reply(typedData: typedData)
        PerplEnrollTransport.replies["/v1/api-key/enroll"] = try JSONSerialization.data(withJSONObject: ["api_key": ["api_key": "token"]])
        let auth = client()
        let payload = try await auth.requestPayload(address: Self.address, publicKeyHex: publicKeyHex, scopeMask: PerplScope.trade, label: "DyorHQ", now: Self.issuedAt)
        XCTAssertEqual(payload.digest, try EIP712.digest(EIP712.parse(typedData)))

        // A different secret or wallet is refused before anything is sent.
        do {
            _ = try await auth.enroll(address: Self.address, secret: PerplAuth.newSecret(), payload: payload, walletSignature: "0x", scopeMask: PerplScope.trade)
            XCTFail("a secret that is not the validated key must be refused")
        } catch { XCTAssertEqual(error as? PerplEnrollmentError, .foreignKey) }
        do {
            _ = try await auth.enroll(address: "0x000000000000000000000000000000000000dEaD", secret: secret, payload: payload, walletSignature: "0x", scopeMask: PerplScope.trade)
            XCTFail("a different wallet must be refused")
        } catch { XCTAssertEqual(error as? PerplEnrollmentError, .foreignSigner) }
        XCTAssertFalse(PerplEnrollTransport.requests.contains { $0.path.hasSuffix("/enroll") })

        let key = try await auth.enroll(address: Self.address, secret: secret, payload: payload, walletSignature: "0x", scopeMask: PerplScope.trade)
        XCTAssertEqual(key.token, "token")
        let sent = try XCTUnwrap(PerplEnrollTransport.requests.last { $0.path.hasSuffix("/enroll") }?.body)
        // The PoP covers the locally computed digest, and the server's typed data is echoed back unchanged.
        let pop = try XCTUnwrap(Data(hex: sent["pop_signature"] as? String ?? ""))
        XCTAssertTrue(try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(pop, for: payload.digest))
        XCTAssertEqual(try EIP712.digest(EIP712.parse(try XCTUnwrap(sent["typed_data"] as? [String: Any]))), payload.digest)
    }
}

/// Serves canned Perpl enrollment replies by path suffix and records every request (path + JSON body).
final class PerplEnrollTransport: URLProtocol {
    static var replies: [String: Data] = [:]
    /// A status other than 200 for a path (default: 200 with a reply, 404 without).
    static var statuses: [String: Int] = [:]
    /// A server with state, when set: answers every request from its path and JSON body instead of `replies`.
    static var respond: ((String, [String: Any]) -> (status: Int, body: Data))?
    static var requests: [(path: String, body: [String: Any])] = []

    static func reset() {
        replies = [:]
        statuses = [:]
        respond = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.requests.append((path, json))
        var data = Self.replies.first { path.hasSuffix($0.key) }?.value
        var status = Self.statuses.first { path.hasSuffix($0.key) }?.value ?? (data == nil ? 404 : 200)
        if let respond = Self.respond { (status, data) = respond(path, json) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
