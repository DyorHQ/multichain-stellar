import Foundation
@testable import LiteClient
import StellarCore
import XCTest

/// Stellar for Privy sign-ins on the phone (DyorHQ/internal ios-app/stellar-v2/privy-stellar-wallets.md §5.2): the
/// raw_sign request the user's Privy key authorizes is exactly the one the Lite API relays; a signature is used only once
/// it verifies for the account's address, so a relay (or Privy) answering with anything else gets nothing attached, sent
/// or signed in; and the plan runner signs through it as it signs with a key on the phone.
final class PrivyWalletTests: XCTestCase {
    private let wallet = try! StellarSigner(seed: [UInt8](repeating: 11, count: 32))
    private let stranger = try! StellarSigner(seed: [UInt8](repeating: 12, count: 32))
    private let digest = [UInt8](0..<32)
    private let now = Date(timeIntervalSince1970: 1_760_600_000)

    // MARK: - The request the phone authorizes

    func testTheRawSignRequestIsTheOneTheRelaySends() throws {
        let request = PrivyRawSignRequest(walletId: "wl1", hash: digest, appId: "app1", now: now)
        XCTAssertEqual(request.url, "https://api.privy.io/v1/wallets/wl1/raw_sign")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.hash, "0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        XCTAssertEqual(request.expiresAt, 1_760_600_120_000, "two minutes, in milliseconds")
        XCTAssertEqual(request.headers, ["privy-app-id": "app1", "privy-request-expiry": "1760600120000"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(request.body), as: UTF8.self),
                       #"{"params":{"hash":"0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}}"#)
    }

    // MARK: - PrivyStellarSigner

    func testItAuthorizesThenSignsThroughTheRelayAndChecksTheAnswer() async throws {
        let relay = FakeRelay(answer: wallet)
        let authorized = Box<PrivyRawSignRequest>()
        let signer = privySigner(relay) { request in
            authorized.set(request)
            return "auth-for-\(request.hash.suffix(4))"
        }
        let signature = try await signer.signHash(digest)
        XCTAssertTrue(StellarSigner.verify(address: wallet.address, message: digest, signature: signature))
        let sent = await relay.sent
        XCTAssertEqual(sent.map(\.request), [try XCTUnwrap(authorized.value)], "the relay got the very request the user's key authorized")
        XCTAssertEqual(sent.map(\.authorization), ["auth-for-1e1f"])
    }

    func testASignatureThatDoesntVerifyIsRefusedWhoeverMadeIt() async throws {
        for answer in [FakeRelay(answer: stranger), FakeRelay(answer: wallet, otherHash: true), FakeRelay(answer: wallet, garbage: true)] {
            let signer = privySigner(answer) { _ in "auth" }
            do {
                _ = try await signer.signHash(digest)
                XCTFail("a bad signature was accepted")
            } catch {
                XCTAssertEqual(error as? StellarSigningError, .badSignature)
            }
        }
    }

    func testNothingReachesTheRelayWithoutTheUsersAuthorization() async throws {
        let relay = FakeRelay(answer: wallet)
        struct Cancelled: Error {}
        let signer = privySigner(relay) { _ in throw Cancelled() }
        do {
            _ = try await signer.signHash(digest)
            XCTFail("signed without an authorization")
        } catch {
            XCTAssertTrue(error is Cancelled)
        }
        let sent = await relay.sent
        XCTAssertTrue(sent.isEmpty)
        do {
            _ = try await privySigner(relay) { _ in "auth" }.signHash(Array(digest.prefix(31)))
            XCTFail("a hash that isn't 32 bytes went out")
        } catch {
            XCTAssertEqual(error as? StellarSigningError, .badSignature)
        }
    }

    func testTheSEP53SignInSignatureGoesThroughTheSameChecks() async throws {
        let message = "DyorHQ Lite sign-in\nNetwork: testnet"
        let remote = try await privySigner(FakeRelay(answer: wallet)) { _ in "auth" }.sep53Signature(for: message)
        XCTAssertEqual(remote, try wallet.signMessage(message), "the same signature a key on the phone makes")
        XCTAssertTrue(StellarSigner.verifyMessage(message, signature: remote, address: wallet.address))
        do {
            _ = try await privySigner(FakeRelay(answer: stranger)) { _ in "auth" }.sep53Signature(for: message)
            XCTFail("another key's sign-in signature was accepted")
        } catch {
            XCTAssertEqual(error as? StellarSigningError, .badSignature)
        }
    }

    // MARK: - Envelopes and the plan runner

    func testAnEnvelopeTakesARemoteSignatureOnlyOnceItVerifies() async throws {
        let xdr = TestTransaction.envelope(source: wallet.address, fee: 100, ops: [.payment(to: stranger.address, stroops: 1)])
        var envelope = try TransactionEnvelope(base64: xdr)
        try await envelope.sign(using: privySigner(FakeRelay(answer: wallet)) { _ in "auth" }, network: .testnet)
        XCTAssertTrue(envelope.isSigned(by: wallet.address, network: .testnet))
        XCTAssertEqual(envelope.signatures.count, 1)

        var refused = try TransactionEnvelope(base64: xdr)
        do {
            try await refused.sign(using: privySigner(FakeRelay(answer: stranger)) { _ in "auth" }, network: .testnet)
            XCTFail("a signature that doesn't verify was attached")
        } catch {
            XCTAssertEqual(error as? StellarSigningError, .badSignature)
        }
        XCTAssertTrue(refused.signatures.isEmpty)
    }

    func testThePlanRunnerSignsThroughAPrivyWalletAndSendsNothingItCantVerify() async throws {
        let pinned = PinnedContracts(network: .testnet, sponsor: stranger.address, launchTokenWasmHash: "", roles: [:])
        let xlm = AssetContract.id(.native, network: .testnet)
        let friend = try StellarSigner(seed: [UInt8](repeating: 13, count: 32)).address
        let xdr = TestTransaction.envelope(source: wallet.address, fee: 100, ops: [.payment(to: friend, stroops: 5_000_000)])
        let intent = Intent(kind: "payment", summary: "", spend: [xlm: "5000000"], ops: ["payment"], to: friend)
        let plan = TestPlan.view([TestPlan.step("s1", "Send", xdr: xdr, intent: intent)])

        let good = FakePlanBackend(plan: plan)
        let runner = PlanRunner(api: good, user: wallet.address, pinned: pinned, inspector: NoLaunchTokens())
        let signer = privySigner(FakeRelay(answer: wallet)) { _ in "auth" }
        _ = try await runner.run(plan, limits: [xlm: 5_000_000], signer: { signer })
        let signed = await good.signed
        XCTAssertTrue(try TransactionEnvelope(base64: XCTUnwrap(signed["s1"])).isSigned(by: wallet.address, network: .testnet))

        let bad = FakePlanBackend(plan: plan)
        let badSigner = privySigner(FakeRelay(answer: stranger)) { _ in "auth" }
        do {
            _ = try await PlanRunner(api: bad, user: wallet.address, pinned: pinned, inspector: NoLaunchTokens())
                .run(plan, limits: [xlm: 5_000_000], signer: { badSigner })
            XCTFail("a step went out with a signature that doesn't verify")
        } catch {
            XCTAssertEqual(error as? StellarSigningError, .badSignature)
        }
        let submitted = await bad.submitted
        XCTAssertTrue(submitted.isEmpty)
    }

    // MARK: - The Lite API's two routes

    func testPrivyWalletAndPrivySignSpeakTheContract() async throws {
        let api = LiteAPI(baseURL: URL(string: "http://privy.test/lite")!, network: "testnet", session: StubServer.session)
        StubServer.serve(try ApiFixtures.data("privy-wallet"))
        let found = try await api.privyWallet(privyToken: "id-token")
        XCTAssertEqual(found, try ApiFixtures.decode("privy-wallet", as: PrivyWallet.self))
        let asked = try XCTUnwrap(StubServer.taken())
        XCTAssertEqual(asked.url?.path, "/lite/v1/privy/wallet")
        XCTAssertNil(asked.value(forHTTPHeaderField: "authorization"), "a public route: no session token")
        XCTAssertEqual(StubServer.json(asked), ["privyToken": "id-token"])

        let signature = try wallet.sign(digest)
        StubServer.serve(Data(#"{"signature":"0x\#(signature.map { String(format: "%02x", $0) }.joined())"}"#.utf8))
        let request = PrivyRawSignRequest(walletId: "wl1", hash: digest, appId: "app1", now: now)
        let answer = try await api.privySign(request, authorization: "auth")
        XCTAssertEqual(answer, signature)
        let sign = try XCTUnwrap(StubServer.taken())
        XCTAssertEqual(sign.url?.path, "/lite/v1/privy/sign")
        XCTAssertNil(sign.value(forHTTPHeaderField: "authorization"))

        StubServer.serve(Data(#"{"signature":"0x1234"}"#.utf8))
        do {
            _ = try await api.privySign(request, authorization: "auth")
            XCTFail("a short signature was taken")
        } catch {
            XCTAssertEqual(error as? LiteAPIError, .decoding("the signature"))
        }
    }

    // MARK: - Which wallet the phone keeps

    func testOnlyAWalletPrivyListsAndThePhoneKeptIsUsed() throws {
        let ours = PrivyWallet(walletId: "wl1", address: wallet.address)
        let theirs = PrivyWallet(walletId: "wl9", address: stranger.address)
        let listing = identityToken(linked: [["type": "email", "address": "a@b.c"],
                                             ["type": "wallet", "chain_type": "ethereum", "address": "0x12"],
                                             ["type": "wallet", "chain_type": "stellar", "address": wallet.address, "id": "wl1"]])
        XCTAssertEqual(PrivyWalletCheck.stellarWallets(inIdentityToken: listing), [.init(id: "wl1", address: wallet.address)])
        XCTAssertTrue(PrivyWalletCheck.accepts(ours, kept: nil, identityToken: listing))
        XCTAssertFalse(PrivyWalletCheck.accepts(theirs, kept: nil, identityToken: listing), "an address Privy doesn't list for the user")
        XCTAssertFalse(PrivyWalletCheck.accepts(PrivyWallet(walletId: "wl2", address: wallet.address), kept: nil, identityToken: listing),
                       "the right address under another wallet id")
        // linked_accounts as an array, and a listing without ids, are read too.
        let array = identityToken(linked: [["type": "wallet", "chain_type": "stellar", "address": wallet.address]], asString: false)
        XCTAssertTrue(PrivyWalletCheck.accepts(ours, kept: nil, identityToken: array))
        XCTAssertFalse(PrivyWalletCheck.accepts(theirs, kept: nil, identityToken: array))
        // A token that lists no Stellar wallet (or can't be read) leaves only what this iPhone kept: the first answer.
        let none = identityToken(linked: [["type": "google_oauth", "email": "a@b.c"]])
        XCTAssertTrue(PrivyWalletCheck.accepts(theirs, kept: nil, identityToken: none))
        XCTAssertTrue(PrivyWalletCheck.accepts(theirs, kept: nil, identityToken: "not a token"))
        XCTAssertTrue(PrivyWalletCheck.accepts(ours, kept: ours, identityToken: none))
        XCTAssertFalse(PrivyWalletCheck.accepts(theirs, kept: ours, identityToken: none), "never another wallet than the one kept")
        XCTAssertFalse(PrivyWalletCheck.accepts(theirs, kept: ours, identityToken: nil))
    }

    // MARK: - Helpers

    /// An identity token as Privy shapes one (its signature isn't read: the SDK fetched it from Privy).
    private func identityToken(linked: [[String: String]], asString: Bool = true) -> String {
        let b64url = { (data: Data) in data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let accounts = try! JSONSerialization.data(withJSONObject: linked)
        let claims: [String: Any] = ["iss": "privy.io", "sub": "did:privy:cmuser",
                                     "linked_accounts": asString ? String(decoding: accounts, as: UTF8.self) : linked]
        let header = b64url(Data(#"{"alg":"ES256","typ":"JWT"}"#.utf8))
        return "\(header).\(b64url(try! JSONSerialization.data(withJSONObject: claims))).c2ln"
    }

    private func privySigner(_ relay: FakeRelay, authorize: @escaping @Sendable (PrivyRawSignRequest) async throws -> String) -> PrivyStellarSigner {
        let now = now
        return PrivyStellarSigner(address: wallet.address, walletId: "wl1", appId: "app1", backend: relay, authorize: authorize, now: { now })
    }
}

/// The Lite API's relay as the signer meets it: Privy's answer made by `answer`'s key, over the hash asked for (or another
/// one, or not a signature at all).
actor FakeRelay: PrivySigningBackend {
    struct Sent: Equatable {
        let request: PrivyRawSignRequest
        let authorization: String
    }

    private let answer: StellarSigner
    private let otherHash: Bool
    private let garbage: Bool
    private(set) var sent: [Sent] = []

    init(answer: StellarSigner, otherHash: Bool = false, garbage: Bool = false) {
        self.answer = answer
        self.otherHash = otherHash
        self.garbage = garbage
    }

    func privySign(_ request: PrivyRawSignRequest, authorization: String) async throws -> [UInt8] {
        sent.append(Sent(request: request, authorization: authorization))
        if garbage { return [UInt8](repeating: 0, count: 64) }
        let hex = String(request.hash.dropFirst(2))
        var bytes: [UInt8] = stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
        }
        if otherHash { bytes[0] ^= 1 }
        return try answer.sign(bytes)
    }
}

/// One value, set from a closure the test can't return it from.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: T?

    func set(_ value: T) { lock.withLock { held = value } }
    var value: T? { lock.withLock { held } }
}
