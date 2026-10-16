import Foundation
@testable import LiteClient
import StellarCore
import XCTest

/// Stellar for Privy sign-ins on the phone (DyorHQ/internal ios-app/stellar-v2/privy-stellar-wallets.md): the raw_sign
/// request the user's Privy key authorizes is exactly the one sent to Privy; a signature is used only once it verifies
/// for the account's address; the wallet used is one Privy says only the user controls (owned by the user's own key
/// quorum, no other signer, not imported), never one someone else made for the user; and the plan runner signs through
/// it as it signs with a key on the phone.
final class PrivyWalletTests: XCTestCase {
    private let key = try! StellarSigner(seed: [UInt8](repeating: 11, count: 32))
    private let stranger = try! StellarSigner(seed: [UInt8](repeating: 12, count: 32))
    private let digest = [UInt8](0..<32)
    private let now = Date(timeIntervalSince1970: 1_760_600_000)
    private var wallet: PrivyStellarWallet { PrivyStellarWallet(walletId: "wl1", address: key.address) }

    // MARK: - The request the phone authorizes

    func testTheRawSignRequestIsPrivysClientRouteAsItsSDKsSignIt() throws {
        let request = PrivyRawSignRequest(walletId: "wl1", hash: digest, appId: "app1", now: now)
        XCTAssertEqual(request.url, "https://auth.privy.io/api/v1/wallets/wl1/raw_sign")
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

    func testItAuthorizesThenSignsAndChecksTheAnswer() async throws {
        let privy = FakePrivy(signer: key)
        let authorized = Box<PrivyRawSignRequest>()
        let signer = privySigner(privy) { request in
            authorized.set(request)
            return "auth-for-\(request.hash.suffix(4))"
        }
        let signature = try await signer.signHash(digest)
        XCTAssertTrue(StellarSigner.verify(address: key.address, message: digest, signature: signature))
        let sent = await privy.signed
        XCTAssertEqual(sent.map(\.request), [try XCTUnwrap(authorized.value)], "Privy got the very request the user's key authorized")
        XCTAssertEqual(sent.map(\.authorization), ["auth-for-1e1f"])
    }

    func testASignatureThatDoesntVerifyIsRefusedWhoeverMadeIt() async throws {
        for privy in [FakePrivy(signer: stranger), FakePrivy(signer: key, otherHash: true), FakePrivy(signer: key, garbage: true)] {
            do {
                _ = try await privySigner(privy) { _ in "auth" }.signHash(digest)
                XCTFail("a bad signature was accepted")
            } catch {
                XCTAssertEqual(error as? StellarSigningError, .badSignature)
            }
        }
    }

    func testNothingReachesPrivyWithoutTheUsersAuthorization() async throws {
        let privy = FakePrivy(signer: key)
        struct Cancelled: Error {}
        do {
            _ = try await privySigner(privy) { _ in throw Cancelled() }.signHash(digest)
            XCTFail("signed without an authorization")
        } catch {
            XCTAssertTrue(error is Cancelled)
        }
        let sent = await privy.signed
        XCTAssertTrue(sent.isEmpty)
        do {
            _ = try await privySigner(privy) { _ in "auth" }.signHash(Array(digest.prefix(31)))
            XCTFail("a hash that isn't 32 bytes went out")
        } catch {
            XCTAssertEqual(error as? StellarSigningError, .badSignature)
        }
    }

    func testTheSEP53SignInSignatureGoesThroughTheSameChecks() async throws {
        let message = "DyorHQ Lite sign-in\nNetwork: testnet"
        let remote = try await privySigner(FakePrivy(signer: key)) { _ in "auth" }.sep53Signature(for: message)
        // CryptoKit's Ed25519 signatures are randomized: the remote one is checked as the API checks a sign-in's.
        XCTAssertTrue(StellarSigner.verifyMessage(message, signature: remote, address: key.address))
        XCTAssertFalse(StellarSigner.verifyMessage(message + "x", signature: remote, address: key.address))
        do {
            _ = try await privySigner(FakePrivy(signer: stranger)) { _ in "auth" }.sep53Signature(for: message)
            XCTFail("another key's sign-in signature was accepted")
        } catch {
            XCTAssertEqual(error as? StellarSigningError, .badSignature)
        }
    }

    // MARK: - Envelopes and the plan runner

    func testAnEnvelopeTakesARemoteSignatureOnlyOnceItVerifies() async throws {
        let xdr = TestTransaction.envelope(source: key.address, fee: 100, ops: [.payment(to: stranger.address, stroops: 1)])
        var envelope = try TransactionEnvelope(base64: xdr)
        try await envelope.sign(using: privySigner(FakePrivy(signer: key)) { _ in "auth" }, network: .testnet)
        XCTAssertTrue(envelope.isSigned(by: key.address, network: .testnet))
        XCTAssertEqual(envelope.signatures.count, 1)

        var refused = try TransactionEnvelope(base64: xdr)
        do {
            try await refused.sign(using: privySigner(FakePrivy(signer: stranger)) { _ in "auth" }, network: .testnet)
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
        let xdr = TestTransaction.envelope(source: key.address, fee: 100, ops: [.payment(to: friend, stroops: 5_000_000)])
        let intent = Intent(kind: "payment", summary: "", spend: [xlm: "5000000"], ops: ["payment"], to: friend)
        let plan = TestPlan.view([TestPlan.step("s1", "Send", xdr: xdr, intent: intent)])

        let good = FakePlanBackend(plan: plan)
        let signer = privySigner(FakePrivy(signer: key)) { _ in "auth" }
        _ = try await PlanRunner(api: good, user: key.address, pinned: pinned, inspector: NoLaunchTokens())
            .run(plan, limits: [xlm: 5_000_000], signer: { signer })
        let signed = await good.signed
        XCTAssertTrue(try TransactionEnvelope(base64: XCTUnwrap(signed["s1"])).isSigned(by: key.address, network: .testnet))

        let bad = FakePlanBackend(plan: plan)
        let badSigner = privySigner(FakePrivy(signer: stranger)) { _ in "auth" }
        do {
            _ = try await PlanRunner(api: bad, user: key.address, pinned: pinned, inspector: NoLaunchTokens())
                .run(plan, limits: [xlm: 5_000_000], signer: { badSigner })
            XCTFail("a step went out with a signature that doesn't verify")
        } catch {
            XCTAssertEqual(error as? StellarSigningError, .badSignature)
        }
        let submitted = await bad.submitted
        XCTAssertTrue(submitted.isEmpty)
    }

    // MARK: - Which wallet is the account's

    private let owner = "kq-user"
    private func record(_ id: String, _ signer: StellarSigner, owner: String? = "kq-user", signers: [String] = [], imported: Bool = false,
                        createdAt: Int64 = 10) -> PrivyWalletRecord {
        PrivyWalletRecord(id: id, address: signer.address, chainType: "stellar", ownerId: owner,
                          additionalSigners: signers.map(PrivyWalletRecord.Signer.init(signerId:)), importedAt: imported ? 5 : nil,
                          createdAt: createdAt)
    }
    private var monad: PrivyWalletRecord {
        PrivyWalletRecord(id: "wl-monad", address: "0x00000000000000000000000000000000000000aa", chainType: "ethereum", ownerId: owner)
    }

    func testOnlyAWalletOnlyTheUserControlsIsTrusted() {
        XCTAssertTrue(PrivyWalletCheck.trusted(record("wl1", key), owner: owner))
        XCTAssertFalse(PrivyWalletCheck.trusted(record("wl1", key, signers: ["kq-someone"]), owner: owner), "another signer")
        XCTAssertFalse(PrivyWalletCheck.trusted(record("wl1", key, owner: "kq-user-and-someone"), owner: owner), "another owner")
        XCTAssertFalse(PrivyWalletCheck.trusted(record("wl1", key, owner: nil), owner: owner), "no owner")
        XCTAssertFalse(PrivyWalletCheck.trusted(record("wl1", key, imported: true), owner: owner), "an imported key")
        XCTAssertFalse(PrivyWalletCheck.trusted(PrivyWalletRecord(id: "wl1", address: "0xabc", chainType: "ethereum", ownerId: owner), owner: owner))
        // A record that doesn't say who else signs counts as one with signers.
        let unsaid = try! JSONDecoder().decode(PrivyWalletRecord.self, from: Data(#"{"id":"wl1","address":"\#(key.address)","chain_type":"stellar","owner_id":"kq-user"}"#.utf8))
        XCTAssertFalse(PrivyWalletCheck.trusted(unsaid, owner: owner))
    }

    func testTheKeptWalletStaysTheAccountsAndIsNeverSwapped() async throws {
        let privy = FakePrivy(signer: key, records: [monad, record("wl1", key)])
        let kept = try await PrivyWalletCheck.resolve(backend: privy, ownerWalletId: "wl-monad", kept: wallet, identityToken: nil)
        XCTAssertEqual(kept, wallet)
        let created = await privy.created
        XCTAssertEqual(created, 0)
        // Someone gave the kept wallet another signer (or it isn't the address kept): refused, never swapped.
        for tampered in [record("wl1", key, signers: ["kq-someone"]), record("wl1", stranger)] {
            let other = FakePrivy(signer: key, records: [monad, tampered, record("wl2", stranger)])
            do {
                _ = try await PrivyWalletCheck.resolve(backend: other, ownerWalletId: "wl-monad", kept: wallet,
                                                       identityToken: identityToken(["wl2": stranger.address]))
                XCTFail("a wallet that isn't only the user's was used")
            } catch {
                XCTAssertEqual(error as? PrivyWalletCheck.Failure, .notOnlyTheUsers)
            }
            let made = await other.created
            XCTAssertEqual(made, 0)
        }
    }

    func testOnANewIPhoneTheOldestWalletOnlyTheUserControlsIsFound() async throws {
        let older = try StellarSigner(seed: [UInt8](repeating: 14, count: 32))
        let privy = FakePrivy(signer: key, records: [
            monad,
            record("wl-backdoor", stranger, signers: ["kq-someone"], createdAt: 1),
            record("wl-shared", stranger, owner: "kq-user-and-someone", createdAt: 2),
            record("wl-imported", stranger, imported: true, createdAt: 3),
            record("wl1", key, createdAt: 20),
            record("wl0", older, createdAt: 10),
        ])
        let token = identityToken(["wl-backdoor": stranger.address, "wl-shared": stranger.address, "wl-imported": stranger.address,
                                   "wl1": key.address, "wl0": older.address, "wl-gone": key.address])
        let found = try await PrivyWalletCheck.resolve(backend: privy, ownerWalletId: "wl-monad", kept: nil, identityToken: token)
        XCTAssertEqual(found, PrivyStellarWallet(walletId: "wl0", address: older.address), "the oldest wallet only the user controls")
        let created = await privy.created
        XCTAssertEqual(created, 0, "nothing is made while one exists")
    }

    func testWhenPrivyListsTheUsersWalletsTheListIsUsedAndTheTokenIsNot() async throws {
        let older = try StellarSigner(seed: [UInt8](repeating: 15, count: 32))
        let privy = FakePrivy(signer: key, records: [monad], listing: [
            record("wl-backdoor", stranger, signers: ["kq-someone"], createdAt: 1),
            record("wl-shared", stranger, owner: "kq-user-and-someone", createdAt: 2),
            record("wl1", key, createdAt: 20),
            record("wl0", older, createdAt: 10),
        ])
        let found = try await PrivyWalletCheck.resolve(backend: privy, ownerWalletId: "wl-monad", kept: nil,
                                                       identityToken: identityToken(["wl-elsewhere": stranger.address]))
        XCTAssertEqual(found, PrivyStellarWallet(walletId: "wl0", address: older.address))
        let created = await privy.created
        XCTAssertEqual(created, 0)
        // An empty list means none yet: one is made.
        let none = FakePrivy(signer: key, records: [monad], make: record("wl-new", key), listing: [])
        let made = try await PrivyWalletCheck.resolve(backend: none, ownerWalletId: "wl-monad", kept: nil, identityToken: nil)
        XCTAssertEqual(made.walletId, "wl-new")
    }

    func testAWalletIsMadeOnlyWhenThereIsNoneAndOnlyKeptIfOnlyTheUsers() async throws {
        let privy = FakePrivy(signer: key, records: [monad], make: record("wl-new", key))
        let made = try await PrivyWalletCheck.resolve(backend: privy, ownerWalletId: "wl-monad", kept: nil, identityToken: identityToken([:]))
        XCTAssertEqual(made, PrivyStellarWallet(walletId: "wl-new", address: key.address))
        let count = await privy.created
        XCTAssertEqual(count, 1)

        let backdoored = FakePrivy(signer: key, records: [monad], make: record("wl-new", key, signers: ["kq-someone"]))
        do {
            _ = try await PrivyWalletCheck.resolve(backend: backdoored, ownerWalletId: "wl-monad", kept: nil, identityToken: identityToken([:]))
            XCTFail("a new wallet with another signer was used")
        } catch {
            XCTAssertEqual(error as? PrivyWalletCheck.Failure, .notOnlyTheUsers)
        }
    }

    func testAWalletIsNeverMadeFromAnIdentityTokenThatMayBeOutOfDate() async throws {
        let privy = FakePrivy(signer: key, records: [monad, record("wl1", key)], make: record("wl-new", key))
        // A stale token that lists the wallet still finds it.
        let found = try await PrivyWalletCheck.resolve(backend: privy, ownerWalletId: "wl-monad", kept: nil,
                                                       identityToken: identityToken(["wl1": key.address]), identityTokenIsFresh: false)
        XCTAssertEqual(found.walletId, "wl1")
        // One that lists none, or no token at all, makes nothing: the wallet may be newer than the token.
        for token in [identityToken([:]), nil] {
            do {
                _ = try await PrivyWalletCheck.resolve(backend: privy, ownerWalletId: "wl-monad", kept: nil, identityToken: token,
                                                       identityTokenIsFresh: false)
                XCTFail("a wallet was made from a list that may be out of date")
            } catch {
                XCTAssertEqual(error as? PrivyWalletCheck.Failure, .listNotFresh)
            }
        }
        let created = await privy.created
        XCTAssertEqual(created, 0)
        // No token even when "fresh" (identity tokens off): nothing to know the list by, nothing made.
        do {
            _ = try await PrivyWalletCheck.resolve(backend: privy, ownerWalletId: "wl-monad", kept: nil, identityToken: nil)
            XCTFail("a wallet was made with no list at all")
        } catch {
            XCTAssertEqual(error as? PrivyWalletCheck.Failure, .listNotFresh)
        }
    }

    func testAnOutageNeverMakesASecondWalletAndNoOwnerIsNoWallet() async throws {
        let privy = FakePrivy(signer: key, records: [monad], down: ["wl1"], make: record("wl-new", key))
        do {
            _ = try await PrivyWalletCheck.resolve(backend: privy, ownerWalletId: "wl-monad", kept: nil, identityToken: identityToken(["wl1": key.address]))
            XCTFail("went on without an answer about a listed wallet")
        } catch {
            XCTAssertEqual(error as? PrivyAPIError, .unavailable(status: 503))
        }
        let created = await privy.created
        XCTAssertEqual(created, 0)

        let ownerless = FakePrivy(signer: key, records: [PrivyWalletRecord(id: "wl-monad", address: "0xaa", chainType: "ethereum", ownerId: nil)])
        do {
            _ = try await PrivyWalletCheck.resolve(backend: ownerless, ownerWalletId: "wl-monad", kept: nil, identityToken: identityToken([:]))
            XCTFail("no owner to compare with")
        } catch {
            XCTAssertEqual(error as? PrivyWalletCheck.Failure, .noOwner)
        }
    }

    // MARK: - Privy's client API

    func testPrivysClientAPIIsCalledAsItsSDKsCallIt() async throws {
        let api = PrivyWalletAPI(appId: "app1", clientId: "client1", nativeAppIdentifier: "fun.dyorhq.app",
                                 accessToken: { "user-access-token" }, session: StubServer.session)
        StubServer.serve(Data(#"{"id":"wl1","address":"\#(key.address)","chain_type":"stellar","owner_id":"kq-user","additional_signers":[],"policy_ids":[],"created_at":1,"exported_at":null,"imported_at":null}"#.utf8))
        let record = try await api.wallet(id: "wl1")
        XCTAssertTrue(PrivyWalletCheck.trusted(record, owner: "kq-user"))
        let get = try XCTUnwrap(StubServer.taken())
        XCTAssertEqual([get.httpMethod, get.url?.absoluteString], ["GET", "https://auth.privy.io/api/v1/wallets/wl1"])
        XCTAssertEqual(get.value(forHTTPHeaderField: "Authorization"), "Bearer user-access-token")
        XCTAssertEqual(get.value(forHTTPHeaderField: "privy-app-id"), "app1")
        XCTAssertEqual(get.value(forHTTPHeaderField: "privy-client-id"), "client1")
        XCTAssertEqual(get.value(forHTTPHeaderField: "x-native-app-identifier"), "fun.dyorhq.app")

        StubServer.serve(Data(#"{"id":"wl1","address":"\#(key.address)","chain_type":"stellar","owner_id":"kq-user","additional_signers":[]}"#.utf8))
        _ = try await api.createStellarWallet()
        let create = try XCTUnwrap(StubServer.taken())
        XCTAssertEqual([create.httpMethod, create.url?.path], ["POST", "/api/v1/wallets"])
        XCTAssertEqual(StubServer.json(create), ["chain_type": "stellar"], "the user's own wallet: no owner, signer or policy is asked for")

        let signature = try key.sign(digest)
        StubServer.serve(Data(#"{"method":"raw_sign","data":{"signature":"0x\#(signature.map { String(format: "%02x", $0) }.joined())","encoding":"hex"}}"#.utf8))
        let request = PrivyRawSignRequest(walletId: "wl1", hash: digest, appId: "app1", now: now)
        let answered = try await api.rawSign(request, authorization: "auth-sig")
        XCTAssertEqual(answered, signature)
        let sign = try XCTUnwrap(StubServer.taken())
        XCTAssertEqual(sign.url?.absoluteString, request.url)
        XCTAssertEqual(sign.value(forHTTPHeaderField: "privy-authorization-signature"), "auth-sig")
        XCTAssertEqual(sign.value(forHTTPHeaderField: "privy-request-expiry"), "1760600120000")
        XCTAssertEqual(sign.value(forHTTPHeaderField: "privy-app-id"), "app1")

        StubServer.serve(Data(#"{"data":[{"id":"wl1","address":"\#(key.address)","chain_type":"stellar","owner_id":"kq-user","additional_signers":[]}],"next_cursor":null}"#.utf8))
        let listed = try await api.stellarWallets()
        XCTAssertEqual(listed?.map(\.id), ["wl1"])
        let list = try XCTUnwrap(StubServer.taken())
        XCTAssertEqual([list.httpMethod, list.url?.absoluteString], ["GET", "https://auth.privy.io/api/v1/wallets?chain_type=stellar"])
        // Privy not listing wallets to the user's session is no list, never an error (it answers 401 to a session the
        // wallet reads take, as it did on testnet); an outage is an error.
        for status in [401, 403, 404] {
            StubServer.serve(Data("{}".utf8), status: status)
            let unlisted = try await api.stellarWallets()
            XCTAssertNil(unlisted, "\(status)")
        }
        StubServer.serve(Data("{}".utf8), status: 503)
        do {
            _ = try await api.stellarWallets()
            XCTFail("an outage read as no list")
        } catch {
            XCTAssertEqual(error as? PrivyAPIError, .unavailable(status: 503))
        }

        for (status, expected) in [(401, PrivyAPIError.refused(status: 401, code: nil)), (403, .refused(status: 403, code: nil)),
                                   (429, .unavailable(status: 429)), (502, .unavailable(status: 502))] {
            StubServer.serve(Data("{}".utf8), status: status)
            do {
                _ = try await api.wallet(id: "wl1")
                XCTFail("\(status) was taken")
            } catch {
                XCTAssertEqual(error as? PrivyAPIError, expected)
            }
        }
        do {
            _ = try await api.wallet(id: "../users/me")
            XCTFail("a path went out as a wallet id")
        } catch {
            XCTAssertEqual(error as? PrivyAPIError, .decoding("a wallet id"))
        }
    }

    func testIdentityTokensListTheirStellarWallets() {
        let token = identityToken(["wl1": key.address])
        XCTAssertEqual(PrivyWalletCheck.stellarWallets(inIdentityToken: token), [.init(id: "wl1", address: key.address)])
        XCTAssertEqual(PrivyWalletCheck.stellarWallets(inIdentityToken: "not a token"), [])
    }

    // MARK: - Helpers

    private func privySigner(_ privy: FakePrivy, authorize: @escaping @Sendable (PrivyRawSignRequest) async throws -> String) -> PrivyStellarSigner {
        let now = now
        return PrivyStellarSigner(wallet: wallet, appId: "app1", backend: privy, authorize: authorize, now: { now })
    }

    /// An identity token as Privy shapes one, its `linked_accounts` a JSON string with an email and the given Stellar
    /// wallets (its signature isn't read: the SDK fetched it from Privy).
    private func identityToken(_ stellar: [String: String]) -> String {
        let b64url = { (data: Data) in data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let linked: [[String: String]] = [["type": "email", "address": "a@b.c"]]
            + stellar.sorted { $0.key < $1.key }.map { ["type": "wallet", "chain_type": "stellar", "id": $0.key, "address": $0.value] }
        let claims: [String: Any] = ["iss": "privy.io", "sub": "did:privy:cmuser",
                                     "linked_accounts": String(decoding: try! JSONSerialization.data(withJSONObject: linked), as: UTF8.self)]
        return "\(b64url(Data(#"{"alg":"ES256","typ":"JWT"}"#.utf8))).\(b64url(try! JSONSerialization.data(withJSONObject: claims))).c2ln"
    }
}

/// Privy as the phone meets it: the wallets it shows this user, the one it makes, and raw_sign by `signer`'s key over
/// the hash asked for (or another one, or not a signature at all). Ids in `down` answer as an outage.
actor FakePrivy: PrivyWalletBackend {
    struct Signed: Equatable {
        let request: PrivyRawSignRequest
        let authorization: String
    }

    private let signer: StellarSigner
    private let otherHash: Bool
    private let garbage: Bool
    private let records: [String: PrivyWalletRecord]
    private let down: Set<String>
    private let make: PrivyWalletRecord?
    private let listing: [PrivyWalletRecord]?
    private(set) var signed: [Signed] = []
    private(set) var created = 0

    /// `listing`: the user's Stellar wallets as Privy lists them to the user's session; nil, Privy doesn't list them.
    init(signer: StellarSigner, otherHash: Bool = false, garbage: Bool = false, records: [PrivyWalletRecord] = [],
         down: Set<String> = [], make: PrivyWalletRecord? = nil, listing: [PrivyWalletRecord]? = nil) {
        self.signer = signer
        self.otherHash = otherHash
        self.garbage = garbage
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        self.down = down
        self.make = make
        self.listing = listing
    }

    func stellarWallets() async throws -> [PrivyWalletRecord]? { listing }

    func wallet(id: String) async throws -> PrivyWalletRecord {
        if down.contains(id) { throw PrivyAPIError.unavailable(status: 503) }
        guard let record = records[id] else { throw PrivyAPIError.refused(status: 404, code: nil) }
        return record
    }

    func createStellarWallet() async throws -> PrivyWalletRecord {
        created += 1
        guard let make else { throw PrivyAPIError.refused(status: 400, code: nil) }
        return make
    }

    func rawSign(_ request: PrivyRawSignRequest, authorization: String) async throws -> [UInt8] {
        signed.append(Signed(request: request, authorization: authorization))
        if garbage { return [UInt8](repeating: 0, count: 64) }
        var bytes = PrivyWalletAPI.hexBytes(request.hash)!
        if otherHash { bytes[0] ^= 1 }
        return try signer.sign(bytes)
    }
}

/// One value, set from a closure the test can't return it from.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: T?

    func set(_ value: T) { lock.withLock { held = value } }
    var value: T? { lock.withLock { held } }
}
