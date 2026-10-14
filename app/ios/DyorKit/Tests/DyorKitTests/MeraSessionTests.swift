import BigInt
import CryptoKit
import XCTest
@testable import DyorKit

/// The signing session in MERA-PLAN §3: a fixed `expiresAt`, a permanent `end()` that zeroes the key copies, the Perpl
/// trading key of each enrolment derived in memory only, enrolment signed inside the session (and again on a fresh
/// device, MERA-PLAN §6), and the $100 / $250 caps.
@MainActor
final class MeraSessionTests: XCTestCase {
    let accountOutput = Data(hex: "0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!
    let utilityOutput = Data(repeating: 0xB2, count: 32)
    let credentialID = Data([1, 2, 3, 4])
    let opened = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(utility: Data? = nil, length: TimeInterval = 15 * 60, openedAt: Date? = nil) -> Mera.SigningSession {
        Mera.SigningSession(account: accountOutput, utility: utility, credentialID: credentialID, length: length, openedAt: openedAt ?? opened)!
    }

    private func assertEnded(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? Mera.SessionError, .sessionEnded, file: file, line: line) }
    }

    private func tx(from: Address) -> PreparedTransaction {
        PreparedTransaction(from: from, to: Address("0x000000000000000000000000000000000000dEaD")!, data: Data(), value: BigUInt(1),
                            nonce: 0, gasLimit: BigUInt(21_000), maxFeePerGas: BigUInt(100_000_000_000), maxPriorityFeePerGas: BigUInt(1), chainId: 143)
    }

    // MARK: Length

    func testSessionLengthChoicesAndSanitising() {
        XCTAssertEqual(Mera.SessionLength.choices, [300, 900, 3600])
        XCTAssertEqual(Mera.SessionLength.standard, 900)
        XCTAssertEqual(Mera.SessionLength.sanitized(300), 300)
        XCTAssertEqual(Mera.SessionLength.sanitized(3600), 3600)
        // Unset (0), odd or tampered values read as the standard length, never a longer one.
        for odd: TimeInterval in [0, -60, 1234, 86_400, .infinity, .nan] { XCTAssertEqual(Mera.SessionLength.sanitized(odd), 900) }
    }

    func testOnlyLengtheningNeedsAStepUp() {
        typealias L = Mera.SessionLength
        XCTAssertTrue(L.needsStepUp(from: 300, to: 900))
        XCTAssertTrue(L.needsStepUp(from: 900, to: 3600))
        XCTAssertTrue(L.needsStepUp(from: 300, to: 3600))
        XCTAssertFalse(L.needsStepUp(from: 3600, to: 300))
        XCTAssertFalse(L.needsStepUp(from: 900, to: 900))
        // An unset stored length is the standard one: going to an hour still needs the owner.
        XCTAssertTrue(L.needsStepUp(from: 0, to: 3600))
    }

    // MARK: Lifetime

    func testExpiresAtIsFixedAtOpen() throws {
        let s = session(length: 300)
        XCTAssertEqual(s.address, Mera.evmAccount(prf: accountOutput)?.address)
        XCTAssertEqual(s.expiresAt, opened.addingTimeInterval(300))
        XCTAssertTrue(s.isLive(at: opened.addingTimeInterval(299)))
        XCTAssertFalse(s.isLive(at: opened.addingTimeInterval(300)))
        XCTAssertNil(Mera.SigningSession(account: Data(count: 31), utility: nil, credentialID: credentialID, length: 300), "no account from a malformed output")
    }

    func testSignsLikeTheDerivedAccountWhileLive() throws {
        let s = session()
        let account = try XCTUnwrap(Mera.evmAccount(prf: accountOutput))
        let now = opened.addingTimeInterval(60)
        XCTAssertEqual(try s.sign(tx(from: s.address), now: now), try account.sign(tx(from: s.address)))
        let message = Data("DyorHQ Sign-In".utf8)
        let signature = try s.signMessage(message, now: now)
        let digest = Keccak.hash256(Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8) + message)
        XCTAssertEqual(Secp256k1Account.recover(hash32: digest, signature: signature), s.address)
    }

    func testEndZeroesTheKeysAndIsPermanent() throws {
        let s = session(utility: utilityOutput)
        XCTAssertTrue(s.holdsKeyMaterial)
        s.end()
        XCTAssertTrue(s.isEnded)
        XCTAssertFalse(s.holdsKeyMaterial, "end() zeroes the wallet key and drops the utility output and the trading secret")
        XCTAssertFalse(s.hasUtility)
        XCTAssertFalse(s.isLive(at: opened))
        // Every later call throws sessionEnded, even well inside the original window.
        let now = opened.addingTimeInterval(1)
        assertEnded { _ = try s.sign(tx(from: s.address), now: now) }
        assertEnded { _ = try s.signMessage(Data("x".utf8), now: now) }
        assertEnded { _ = try s.perplApiKey(token: "t", scopeMask: PerplScope.trade, keyNonce: nil, now: now) }
        assertEnded { _ = try s.charge(usd: 1, now: now) }
        assertEnded { try s.attachUtility(utilityOutput, now: now) }
        s.end() // idempotent
        XCTAssertTrue(s.isEnded)
    }

    func testExpiryEndsTheSessionForGood() {
        let s = session(utility: utilityOutput, length: 300)
        assertEnded { _ = try s.signMessage(Data("late".utf8), now: opened.addingTimeInterval(301)) }
        XCTAssertTrue(s.isEnded, "the first call after expiry ends the session")
        XCTAssertFalse(s.holdsKeyMaterial)
        // A clock that moves back doesn't reopen it.
        assertEnded { _ = try s.signMessage(Data("again".utf8), now: opened.addingTimeInterval(10)) }
    }

    // MARK: Perpl trading key

    func testPerplSecretIsDerivedFromTheUtilityOutputPerEnrolment() throws {
        let now = opened.addingTimeInterval(1)
        let s = session(utility: utilityOutput)
        XCTAssertTrue(s.hasUtility)
        // A token enrolled before enrolments carried a nonce keeps the purpose's own key.
        let legacy = try XCTUnwrap(try s.perplApiKey(token: "token", scopeMask: PerplScope.trade, keyNonce: nil, now: now))
        XCTAssertEqual(legacy.secret, Mera.derivedKey(prf: utilityOutput, purpose: Mera.Purpose.perplTrading))
        XCTAssertEqual(legacy.token, "token")
        XCTAssertEqual(legacy.address, s.address.checksummed)
        XCTAssertEqual(legacy.scopeMask, PerplScope.trade)
        XCTAssertEqual(try s.perplApiKey(token: "token", scopeMask: PerplScope.trade, keyNonce: Data(), now: now), legacy, "an empty nonce is no nonce")
        // Every enrolment since has a key of its own, under the purpose and its nonce…
        let nonce = Data(repeating: 0xAB, count: 16)
        let enrolled = try XCTUnwrap(try s.perplApiKey(token: "token", scopeMask: PerplScope.trade, keyNonce: nonce, now: now))
        XCTAssertEqual(Mera.Purpose.perplTrading(nonce: nonce), "dyorhq.perpl-trading.v1/" + String(repeating: "ab", count: 16))
        XCTAssertEqual(enrolled.secret, Mera.derivedKey(prf: utilityOutput, purpose: "dyorhq.perpl-trading.v1/" + String(repeating: "ab", count: 16)))
        XCTAssertNotEqual(enrolled.secret, legacy.secret)
        XCTAssertNotEqual(try s.perplApiKey(token: "token", scopeMask: PerplScope.trade, keyNonce: Data(repeating: 0xAC, count: 16), now: now)?.secret, enrolled.secret)
        // …which the same passkey and the stored nonce give back in any later session: the nonce alone is not the key.
        XCTAssertEqual(try session(utility: utilityOutput).perplApiKey(token: "token", scopeMask: PerplScope.trade, keyNonce: nonce, now: now), enrolled)
        XCTAssertNotEqual(try session(utility: Data(repeating: 0xB3, count: 32)).perplApiKey(token: "token", scopeMask: PerplScope.trade, keyNonce: nonce, now: now)?.secret, enrolled.secret)
        // Fresh nonces are 16 random bytes.
        XCTAssertEqual(Mera.Purpose.newPerplNonce().count, 16)
        XCTAssertNotEqual(Mera.Purpose.newPerplNonce(), Mera.Purpose.newPerplNonce())
    }

    func testUtilityFetchedLaterIsAttachedOnlyToALiveSession() throws {
        let now = opened.addingTimeInterval(1)
        let s = session(utility: nil)
        XCTAssertFalse(s.hasUtility)
        XCTAssertNil(try s.perplApiKey(token: "token", scopeMask: PerplScope.trade, keyNonce: nil, now: now))
        XCTAssertThrowsError(try s.attachUtility(Data(count: 31), now: now)) { XCTAssertEqual($0 as? Mera.SessionError, .malformedOutput) }
        try s.attachUtility(utilityOutput, now: now)
        XCTAssertNotNil(try s.perplApiKey(token: "token", scopeMask: PerplScope.trade, keyNonce: nil, now: now))
        // A malformed utility output at open counts as missing.
        XCTAssertFalse(session(utility: Data(count: 16)).hasUtility)
        // The prompt outlived the session: nothing is attached to it.
        let ended = session(utility: nil)
        ended.end()
        assertEnded { try ended.attachUtility(utilityOutput, now: now) }
        XCTAssertFalse(ended.holdsKeyMaterial)
    }

    // MARK: Perpl enrolment inside the session

    private func enrolmentClient() -> PerplAuthClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PerplEnrollTransport.self]
        return PerplAuthClient(chainId: 143, apiBase: URL(string: "https://perpl.test/api")!, session: URLSession(configuration: configuration))
    }

    /// Perpl's genuine payload, re-issued for `signer` and the Ed25519 public key it registers. Nonisolated: the
    /// stateful test server calls it from the URL loading thread.
    nonisolated private static func payload(signer: Address, publicKey: Data) throws -> Data {
        var typedData = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(PerplEnrollmentTests.genuineJSON.utf8)) as? [String: Any])
        var message = try XCTUnwrap(typedData["message"] as? [String: Any])
        message["signer"] = signer.checksummed
        message["publicKey"] = PerplAuth.base64url(publicKey)
        typedData["message"] = message
        return try JSONSerialization.data(withJSONObject: ["typed_data": typedData, "mac": "0x" + String(repeating: "ab", count: 32)])
    }

    /// The payload for this session's wallet and the trading key of the enrolment `keyNonce` names.
    private func payload(for s: Mera.SigningSession, keyNonce: Data?) throws -> Data {
        let secret = Mera.derivedKey(prf: utilityOutput, purpose: Mera.Purpose.perplTrading(nonce: keyNonce))
        return try Self.payload(signer: s.address, publicKey: try XCTUnwrap(Data(hex: try PerplAuth.publicKeyHex(secret: secret))))
    }

    func testEnrolmentSignsTheValidatedDigestInsideTheSession() async throws {
        PerplEnrollTransport.reset()
        defer { PerplEnrollTransport.reset() }
        let issuedAt = PerplEnrollmentTests.issuedAt
        let nonce = Data(repeating: 0x5A, count: 16)
        let s = session(utility: utilityOutput, openedAt: issuedAt.addingTimeInterval(-60))
        PerplEnrollTransport.replies["/v1/api-key/payload"] = try payload(for: s, keyNonce: nonce)
        PerplEnrollTransport.replies["/v1/api-key/enroll"] = try JSONSerialization.data(withJSONObject: ["api_key": ["api_key": "token"]])

        let key = try await s.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: nonce, now: { issuedAt })
        XCTAssertEqual(key.token, "token")
        XCTAssertEqual(key.secret, Mera.derivedKey(prf: utilityOutput, purpose: Mera.Purpose.perplTrading(nonce: nonce)))
        // The key the socket signs with later, from the stored token and nonce, is the one enrolled.
        XCTAssertEqual(try s.perplApiKey(token: "token", scopeMask: PerplScope.trade, keyNonce: nonce, now: issuedAt), key)

        let sent = try XCTUnwrap(PerplEnrollTransport.requests.last { $0.path.hasSuffix("/enroll") }?.body)
        let digest = try EIP712.digest(EIP712.parse(try XCTUnwrap(sent["typed_data"] as? [String: Any])))
        // The wallet signature is this account's, over the digest recomputed from the validated typed data…
        let signature = try XCTUnwrap(Data(hex: sent["signature"] as? String ?? ""))
        XCTAssertEqual(Secp256k1Account.recover(hash32: digest, signature: signature), s.address)
        // …and the proof of possession is the passkey-derived trading key's.
        let pop = try XCTUnwrap(Data(hex: sent["pop_signature"] as? String ?? ""))
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key.secret).publicKey
        XCTAssertTrue(publicKey.isValidSignature(pop, for: digest))
    }

    /// MERA-PLAN §6, Perpl's part of the stateless test. Perpl registers a public key once (409 for any second
    /// enrolment of it) and hands its token out once, so a fresh device — or this one after Forget This Device — can
    /// only get trading back by enrolling a key of its own. With a fresh nonce it does; the old nonce's key is refused.
    func testAFreshDeviceEnrolsAgainWithAKeyOfItsOwn() async throws {
        PerplEnrollTransport.reset()
        defer { PerplEnrollTransport.reset() }
        let issuedAt = PerplEnrollmentTests.issuedAt
        // A Perpl that behaves as documented: the payload names the key asked for; enrol registers it once.
        final class Perpl: @unchecked Sendable { var registered = Set<String>(); var asked: String?; var tokens = 0 }
        let perpl = Perpl()
        PerplEnrollTransport.respond = { path, body in
            if path.hasSuffix("/payload") {
                perpl.asked = body["public_key"] as? String
                guard let asked = perpl.asked, let key = Data(hex: asked), let signer = Address(body["address"] as? String ?? ""),
                      let data = try? MeraSessionTests.payload(signer: signer, publicKey: key) else { return (400, Data("{}".utf8)) }
                return (200, data)
            }
            guard let asked = perpl.asked, perpl.registered.insert(asked.lowercased()).inserted else { return (409, Data("{}".utf8)) }
            perpl.tokens += 1
            return (200, try! JSONSerialization.data(withJSONObject: ["api_key": ["api_key": "token-\(perpl.tokens)"]]))
        }

        // The first device enrols.
        let first = session(utility: utilityOutput, openedAt: issuedAt.addingTimeInterval(-60))
        let firstNonce = Mera.Purpose.newPerplNonce()
        let firstKey = try await first.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: firstNonce, now: { issuedAt })
        XCTAssertEqual(firstKey.token, "token-1")

        // A fresh device: the same passkey, no token. Enrolling the same key again is refused, in words…
        let fresh = session(utility: utilityOutput, openedAt: issuedAt.addingTimeInterval(-60))
        do {
            _ = try await fresh.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: firstNonce, now: { issuedAt })
            XCTFail("Perpl never registers a key twice")
        } catch { XCTAssertEqual(error as? PerplEnrollRefusal, .keyAlreadyRegistered) }
        // …and so is the pre-nonce key, once it is registered.
        _ = try await fresh.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: Data(), now: { issuedAt })
        do {
            _ = try await fresh.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: Data(), now: { issuedAt })
            XCTFail("the pre-nonce key can be enrolled on one device only")
        } catch { XCTAssertEqual(error as? PerplEnrollRefusal, .keyAlreadyRegistered) }

        // A fresh nonce, as every enrolment now draws, is a new key: accepted, with a token of its own.
        let freshNonce = Mera.Purpose.newPerplNonce()
        let freshKey = try await fresh.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: freshNonce, now: { issuedAt })
        XCTAssertEqual(freshKey.token, "token-3")
        XCTAssertNotEqual(freshKey.secret, firstKey.secret)
        XCTAssertEqual(freshKey.address, firstKey.address, "the same wallet, a second trading key")
        XCTAssertEqual(try fresh.perplApiKey(token: freshKey.token, scopeMask: PerplScope.trade, keyNonce: freshNonce, now: issuedAt), freshKey)
    }

    func testPerplRefusalsAtEnrolmentAreExplained() async throws {
        PerplEnrollTransport.reset()
        defer { PerplEnrollTransport.reset() }
        let issuedAt = PerplEnrollmentTests.issuedAt
        let nonce = Data(repeating: 0x11, count: 16)
        let s = session(utility: utilityOutput, openedAt: issuedAt.addingTimeInterval(-60))
        PerplEnrollTransport.replies["/v1/api-key/payload"] = try payload(for: s, keyNonce: nonce)
        PerplEnrollTransport.replies["/v1/api-key/enroll"] = Data("{}".utf8)
        for (status, refusal) in [(409, PerplEnrollRefusal.keyAlreadyRegistered), (423, .keyLimitReached)] {
            PerplEnrollTransport.statuses["/v1/api-key/enroll"] = status
            do {
                _ = try await s.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: nonce, now: { issuedAt })
                XCTFail("status \(status) enrols nothing")
            } catch { XCTAssertEqual(error as? PerplEnrollRefusal, refusal) }
        }
        XCTAssertTrue(PerplEnrollRefusal.keyLimitReached.localizedDescription.contains("16"))
        // Any other failure keeps its generic error.
        PerplEnrollTransport.statuses["/v1/api-key/enroll"] = 500
        do {
            _ = try await s.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: nonce, now: { issuedAt })
            XCTFail("status 500 enrols nothing")
        } catch { XCTAssertEqual(error as? PerplError, .contextUnavailable(status: 500)) }
    }

    func testEnrolmentNeedsALiveSessionWithTheUtilityOutput() async throws {
        PerplEnrollTransport.reset()
        defer { PerplEnrollTransport.reset() }
        let issuedAt = PerplEnrollmentTests.issuedAt
        let nonce = Data(repeating: 0x22, count: 16)
        let ended = session(utility: utilityOutput, openedAt: issuedAt.addingTimeInterval(-60))
        ended.end()
        do {
            _ = try await ended.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: nonce, now: { issuedAt })
            XCTFail("an ended session enrols nothing")
        } catch { XCTAssertEqual(error as? Mera.SessionError, .sessionEnded) }

        let single = session(utility: nil, openedAt: issuedAt.addingTimeInterval(-60))
        do {
            _ = try await single.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: nonce, now: { issuedAt })
            XCTFail("no trading key without the utility output")
        } catch { XCTAssertEqual(error as? Mera.SessionError, .noUtilityOutput) }
        XCTAssertTrue(PerplEnrollTransport.requests.isEmpty, "refused before anything reached the server")

        // A session that expires while the payload is in flight signs nothing.
        let expiring = session(utility: utilityOutput, length: 300, openedAt: issuedAt.addingTimeInterval(-60))
        PerplEnrollTransport.replies["/v1/api-key/payload"] = try payload(for: expiring, keyNonce: nonce)
        var clock = [issuedAt, issuedAt, expiring.expiresAt.addingTimeInterval(1)]
        do {
            _ = try await expiring.enrollPerpl(auth: enrolmentClient(), label: "DyorHQ", keyNonce: nonce, now: { clock.count > 1 ? clock.removeFirst() : clock[0] })
            XCTFail("an expired session must not sign the enrolment")
        } catch { XCTAssertEqual(error as? Mera.SessionError, .sessionEnded) }
        XCTAssertFalse(PerplEnrollTransport.requests.contains { $0.path.hasSuffix("/enroll") })
        XCTAssertTrue(expiring.isEnded)
    }

    // MARK: Caps

    func testCapsAllowUpToOneHundredPerActionAndTwoFiftyPerSession() {
        var caps = Mera.SpendingCaps()
        XCTAssertEqual(caps.charge(100), .allowed)
        XCTAssertEqual(caps.charge(100.01), .overActionCap)
        XCTAssertEqual(caps.charge(100), .allowed)
        XCTAssertEqual(caps.charge(60), .overSessionCap, "only $50 left")
        XCTAssertEqual(caps.spentUSD, 200, "refused charges record nothing")
        XCTAssertEqual(caps.charge(50), .allowed)
        XCTAssertEqual(caps.remainingUSD, 0)
        XCTAssertEqual(caps.charge(0.01), .overSessionCap)
        caps.refund(50)
        XCTAssertEqual(caps.remainingUSD, 50)
        caps.refund(1_000)
        XCTAssertEqual(caps.spentUSD, 0, "a refund never goes below zero")
        // Unpriced is never prompt-free.
        for usd: Double? in [nil, -1, .nan, .infinity] { XCTAssertEqual(caps.verdict(for: usd), .unpriced) }
        // Float noise doesn't tip an exact fit over.
        var dimes = Mera.SpendingCaps()
        var allowed = 0
        for _ in 0..<2_500 where dimes.charge(0.1) == .allowed { allowed += 1 }
        XCTAssertEqual(allowed, 2_500, "2 500 × $0.10 is exactly the session cap")
        XCTAssertEqual(dimes.verdict(for: 0.01), .overSessionCap)
    }

    func testSessionChargesAreItsOwn() throws {
        let now = opened.addingTimeInterval(1)
        let first = session()
        XCTAssertEqual(try first.charge(usd: 100, now: now), .allowed)
        XCTAssertEqual(try first.charge(usd: 100, now: now), .allowed)
        XCTAssertEqual(try first.charge(usd: 60, now: now), .overSessionCap)
        first.refund(usd: 100)
        XCTAssertEqual(first.caps.spentUSD, 100)
        // A new session (a new ceremony) starts with the whole budget.
        XCTAssertEqual(try session().charge(usd: 100, now: now), .allowed)
    }

    func testPerpNotionalIsTheWorstFill() throws {
        let market = PerpMarket(id: 1, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0,
                                mark: 100, last: 100, oracle: 100, markTimestamp: 0, longOI: 0, shortOI: 0,
                                fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
        typealias C = Mera.SpendingCaps
        // Market: the mark moved by the whole slippage allowance, whatever the leverage.
        XCTAssertEqual(try XCTUnwrap(C.notionalUSD(of: OrderInput(market: market, side: .long, kind: .market, size: 0.5, leverage: 20, slippageBps: 100))), 50.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(C.notionalUSD(of: OrderInput(market: market, side: .short, kind: .market, size: 0.5, leverage: 1, slippageBps: 0))), 50, accuracy: 1e-9)
        // Limit: the higher of the limit and the mark.
        XCTAssertEqual(try XCTUnwrap(C.notionalUSD(of: OrderInput(market: market, side: .long, kind: .limit, size: 2, price: 150, leverage: 5))), 300, accuracy: 1e-9, "a long limited above the mark")
        XCTAssertEqual(try XCTUnwrap(C.notionalUSD(of: OrderInput(market: market, side: .short, kind: .limit, size: 0.5, price: 150, leverage: 5))), 75, accuracy: 1e-9, "a short resting above the mark")
        XCTAssertEqual(try XCTUnwrap(C.notionalUSD(of: OrderInput(market: market, side: .long, kind: .limit, size: 2, price: 30, leverage: 5))), 200, accuracy: 1e-9, "a bid below the mark, valued at the mark")
        // A short limited far below the mark crosses the book and fills near the mark: $200 of notional, not the $2 the
        // limit alone says, so it is over the per-action cap.
        let marketableShort = OrderInput(market: market, side: .short, kind: .limit, size: 2, price: 1, leverage: 5)
        XCTAssertEqual(try XCTUnwrap(C.notionalUSD(of: marketableShort)), 200, accuracy: 1e-9)
        XCTAssertEqual(Mera.SpendingCaps().verdict(for: C.notionalUSD(of: marketableShort)), .overActionCap)
        // Unpriceable: no mark, or no size.
        let dark = PerpMarket(id: 2, symbol: "X", name: "X", priceDecimals: 1, lotDecimals: 1, basePricePNS: 0, mark: 0, last: 0, oracle: 0, markTimestamp: 0,
                              longOI: 0, shortOI: 0, fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
        XCTAssertNil(C.notionalUSD(of: OrderInput(market: dark, side: .long, kind: .market, size: 1, leverage: 1)))
        XCTAssertNil(C.notionalUSD(of: OrderInput(market: market, side: .long, kind: .market, size: 0, leverage: 1)))
        // $101 of notional is over the per-action cap even at 1% margin.
        XCTAssertEqual(Mera.SpendingCaps().verdict(for: C.notionalUSD(of: OrderInput(market: market, side: .long, kind: .limit, size: 1.01, price: 100, leverage: 50))), .overActionCap)
    }
}
