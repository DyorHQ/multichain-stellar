import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LiteClient
import StellarCore
import XCTest

/// Sessions without gating (DESIGN-stellar-parity §5.8, §6.18): the sign-in signs only the exact challenge and sends
/// only a SEP-53 signature it checked; a refresh keeps the rotated token and never presents one twice; a 401 runs one
/// shared renewal and one retry, then falls back to the public view (viewer routes) or `notSignedIn` (session routes,
/// and reads about an account with no viewer).
final class LiteSessionAPITests: XCTestCase {
    private let base = URL(string: "https://lite.test/functions/v1/lite")!
    private let signer = try! StellarSigner(seed: [UInt8](repeating: 7, count: 32))
    private let other = try! StellarSigner(seed: [UInt8](repeating: 9, count: 32))
    private let nonce = "f1xtur3n0nc3-Q2hhbGxlbmdl"

    override func setUp() {
        SessionServer.reset()
    }

    private func api(network: String? = "testnet") -> LiteAPI {
        LiteAPI(baseURL: base, network: network, session: SessionServer.session)
    }

    private func challenge(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    private func lines(network: String = "testnet", address: String? = nil, nonce: String? = nil, issued: String = "2026-10-14T09:41:00.000Z") -> [String] {
        ["DyorHQ Lite sign-in", "Network: \(network)", "Address: \(address ?? signer.address)", "Nonce: \(nonce ?? self.nonce)", "Issued: \(issued)"]
    }

    /// The server's answers: the challenge (with `nonce`), then `verify` for auth/verify.
    private func serveSignIn(message: String, nonce: String? = nil, verify: String = "auth-verify") throws {
        let challenge = try JSONEncoder().encode(["nonce": nonce ?? self.nonce, "message": message, "expiresAt": "2026-10-14T09:46:00.000Z"])
        let verified = try ApiFixtures.data(verify)
        SessionServer.handle { request in
            request.route == "/v1/auth/challenge" ? (200, challenge) : (200, verified)
        }
    }

    // MARK: - Sign-in

    func testSignsOnlyTheExactChallenge() async throws {
        let good = lines()
        let refusals: [(String, String, String?)] = [
            ("another network", challenge(lines(network: "mainnet")), nil),
            ("another address", challenge(lines(address: other.address)), nil),
            ("another nonce than the answer's", challenge(lines(nonce: "an0th3r-n0nc3-Q2hhbGxlbmdl")), nil),
            ("a nonce too short", challenge(lines(nonce: "abc123")), "abc123"),
            ("a nonce too long", challenge(lines(nonce: String(repeating: "a", count: 65))), String(repeating: "a", count: 65)),
            ("a nonce with other characters", challenge(lines(nonce: "f1xtur3n0nc3+Q2hhbGxl/mdl")), "f1xtur3n0nc3+Q2hhbGxl/mdl"),
            ("another first line", challenge(["DyorHQ Lite sign in"] + good.dropFirst()), nil),
            ("an extra line", challenge(good + ["Pay: 100 XLM"]), nil),
            ("a line before", challenge(["Approve"] + good), nil),
            ("a missing line", challenge(Array(good.dropLast())), nil),
            ("a trailing newline", challenge(good) + "\n", nil),
            ("CRLF line ends", good.joined(separator: "\r\n"), nil),
            ("a combining mark", challenge(["DyorHQ Lite sign-in\u{301}"] + good.dropFirst()), nil),
            ("a time that isn't ISO 8601", challenge(lines(issued: "yesterday")), nil),
            ("words after the time", challenge(lines(issued: "2026-10-14T09:41:00.000Z and a payment")), nil),
            ("a date without a time", challenge(lines(issued: "2026-10-14")), nil),
            ("a month that doesn't exist", challenge(lines(issued: "2026-13-14T09:41:00.000Z")), nil),
            ("more than 512 bytes", challenge(good) + String(repeating: " ", count: 600), nil),
            ("nothing", "", nil),
        ]
        for (label, message, nonce) in refusals {
            SessionServer.reset()
            try serveSignIn(message: message, nonce: nonce)
            let signed = Counter()
            do {
                _ = try await api().signIn(address: signer.address, inviteCode: "DYOR-TEST") { [signer] message in
                    signed.add()
                    return try signer.signMessage(message)
                }
                XCTFail("\(label): signed in")
            } catch let error as LiteAPIError {
                XCTAssertEqual(error, .decoding("the sign-in challenge"), label)
            }
            XCTAssertEqual(signed.count, 0, "\(label): sign was called")
            XCTAssertEqual(SessionServer.seen.map(\.route), ["/v1/auth/challenge"], "\(label): sent more than the challenge")
        }
    }

    /// With no network pinned, any network name passes, and nothing else changes.
    func testANetworkNameIsCheckedOnlyWhenPinned() async throws {
        try serveSignIn(message: challenge(lines(network: "futurenet")))
        _ = try await api(network: nil).signIn(signer: signer)
        SessionServer.reset()
        try serveSignIn(message: challenge(lines(network: "test net")))
        do {
            _ = try await api(network: nil).signIn(signer: signer)
            XCTFail("signed a network name with a space")
        } catch LiteAPIError.decoding {}
    }

    func testOnlyACheckedSEP53SignatureIsSent() async throws {
        let message = challenge(lines())
        let refusals: [(String, @Sendable (String) throws -> String)] = [
            // A raw ed25519 signature of the message: what a key provider without the SEP-53 prefix would return.
            ("without the SEP-53 prefix", { [signer] in Data(try signer.sign(Array($0.utf8))).base64EncodedString() }),
            ("of another message", { [signer] _ in try signer.signMessage("DyorHQ Lite sign-in") }),
            ("by another key", { [other] in try other.signMessage($0) }),
            ("not base64", { _ in "not a signature" }),
            ("too short", { [signer] in String(try signer.signMessage($0).dropLast(8)) }),
        ]
        for (label, sign) in refusals {
            SessionServer.reset()
            try serveSignIn(message: message)
            do {
                _ = try await api().signIn(address: signer.address) { try sign($0) }
                XCTFail("\(label): signed in")
            } catch let error as LiteAPIError {
                XCTAssertEqual(error, .decoding("the sign-in signature"), label)
            }
            XCTAssertEqual(SessionServer.seen.map(\.route), ["/v1/auth/challenge"], "\(label): reached auth/verify")
        }
    }

    func testSignInSendsTheSignatureAndKeepsTheSession() async throws {
        let message = challenge(lines())
        try serveSignIn(message: message)
        let api = api()
        let result = try await api.signIn(address: signer.address, inviteCode: "DYOR-TEST") { [signer] in try signer.signMessage($0) }
        let verify = try XCTUnwrap(SessionServer.seen.last)
        XCTAssertEqual(SessionServer.seen.map(\.route), ["/v1/auth/challenge", "/v1/auth/verify"])
        XCTAssertNil(verify.authorization)
        let body = try XCTUnwrap(verify.json)
        XCTAssertEqual(body["address"], signer.address)
        XCTAssertEqual(body["nonce"], nonce)
        XCTAssertEqual(body["inviteCode"], "DYOR-TEST")
        XCTAssertTrue(StellarSigner.verifyMessage(message, signature: try XCTUnwrap(body["signature"]), address: signer.address))
        let token = await api.token
        let refresh = await api.refreshToken
        let refreshExpiry = await api.refreshExpiry
        let viewer = await api.viewerAddress
        XCTAssertEqual(token, result.token)
        XCTAssertEqual(refresh, result.refreshToken)
        XCTAssertNotNil(refresh)
        XCTAssertEqual(refreshExpiry, ISO8601DateFormatter.lite.date(from: "2026-11-13T09:41:00.000Z"))
        XCTAssertEqual(viewer, signer.address)

        // Today's servers answer without a refresh token; the signer's own sign-in still works.
        SessionServer.reset()
        try serveSignIn(message: message, verify: "auth-verify.legacy")
        let legacy = try await api.signIn(signer: signer)
        XCTAssertNil(legacy.refreshToken)
        let none = await api.refreshToken
        XCTAssertNil(none)
        XCTAssertNil(SessionServer.seen.last?.json?["inviteCode"])
    }

    // MARK: - Refresh and revoke

    func testRefreshKeepsTheRotatedToken() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60), refreshToken: "lrt_first", refreshExpiresAt: Date().addingTimeInterval(86_400))
        let rotated = try ApiFixtures.decode("auth-refresh", as: AuthResult.self)
        let answer = try ApiFixtures.data("auth-refresh")
        SessionServer.handle { request in
            switch request.route {
            case "/v1/auth/refresh": return (200, answer)
            case "/v1/portfolio?period=week": return request.authorization == "Bearer \(rotated.token)" ? (200, try! ApiFixtures.data("portfolio")) : (401, SessionServer.unauthorized)
            default: return (404, Data())
            }
        }
        let result = try await api.refresh(address: signer.address, refreshToken: "lrt_first")
        XCTAssertEqual(result, rotated)
        let sent = try XCTUnwrap(SessionServer.seen.first)
        XCTAssertNil(sent.authorization)
        XCTAssertEqual(sent.json, ["address": signer.address, "refreshToken": "lrt_first"])
        let token = await api.token
        let expiry = await api.tokenExpiry
        let refresh = await api.refreshToken
        let refreshExpiry = await api.refreshExpiry
        XCTAssertEqual(token, rotated.token)
        XCTAssertEqual(expiry, ISO8601DateFormatter.lite.date(from: rotated.expiresAt))
        XCTAssertEqual(refresh, rotated.refreshToken)
        XCTAssertEqual(refreshExpiry, rotated.refreshExpiresAt.flatMap(ISO8601DateFormatter.lite.date(from:)))
        _ = try await api.portfolio(period: .week)
        XCTAssertEqual(SessionServer.seen.last?.authorization, "Bearer \(rotated.token)")
    }

    func testARefusedRefreshTokenIsDropped() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date(), refreshToken: "lrt_used", refreshExpiresAt: Date().addingTimeInterval(86_400))
        let reused = try ApiFixtures.data("error-refresh-reused")
        SessionServer.handle { _ in (401, reused) }
        do {
            _ = try await api.refresh(address: signer.address, refreshToken: "lrt_used")
            XCTFail("a reused refresh token renewed")
        } catch let error as LiteAPIError {
            XCTAssertEqual(error.code, "refresh_reused")
        }
        let refresh = await api.refreshToken
        XCTAssertNil(refresh)
    }

    /// A renewal before expiry and one after a 401 refreshing the same token at once: one request, one rotation, the
    /// same answer for both.
    func testRefreshesOfOneTokenAtOnceShareOneRequest() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60), refreshToken: "lrt_first", refreshExpiresAt: Date().addingTimeInterval(86_400))
        let answer = try ApiFixtures.data("auth-refresh")
        SessionServer.handle { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return (200, answer)
        }
        async let first = api.refresh(address: signer.address, refreshToken: "lrt_first")
        async let second = api.refresh(address: signer.address, refreshToken: "lrt_first")
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(SessionServer.seen.map(\.route), ["/v1/auth/refresh"])
        let refresh = await api.refreshToken
        XCTAssertEqual(refresh, a.refreshToken)
    }

    /// A refresh token rotated here is never presented again (that would end its family): the one it was rotated to
    /// goes instead, and with none held nothing is sent.
    func testARotatedRefreshTokenIsNeverPresentedAgain() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60), refreshToken: "lrt_first", refreshExpiresAt: Date().addingTimeInterval(86_400))
        let rotated = try ApiFixtures.decode("auth-refresh", as: AuthResult.self)
        let successor = try XCTUnwrap(rotated.refreshToken)
        let answer = try ApiFixtures.data("auth-refresh")
        SessionServer.handle { _ in (200, answer) }
        _ = try await api.refresh(address: signer.address, refreshToken: "lrt_first")
        // A caller that read the stored token before that rotation finished.
        _ = try await api.refresh(address: signer.address, refreshToken: "lrt_first")
        XCTAssertEqual(SessionServer.seen.map { $0.json?["refreshToken"] }, ["lrt_first", successor])

        SessionServer.reset(keepingHandler: true)
        await api.signOut()
        for spent in ["lrt_first", successor] {
            do {
                _ = try await api.refresh(address: signer.address, refreshToken: spent)
                XCTFail("\(spent) was presented again")
            } catch let error as LiteAPIError {
                XCTAssertEqual(error, .notSignedIn)
            }
        }
        XCTAssertEqual(SessionServer.seen.count, 0)
    }

    func testRevokeIsBestEffort() async throws {
        let api = api()
        await api.restore(token: "t", expiresAt: Date(), refreshToken: "lrt_mine", refreshExpiresAt: Date())
        SessionServer.handle { _ in (204, Data()) }
        await api.revoke(refreshToken: "lrt_mine")
        XCTAssertEqual(SessionServer.seen.map(\.route), ["/v1/auth/signout"])
        XCTAssertEqual(SessionServer.seen.first?.json, ["refreshToken": "lrt_mine"])
        XCTAssertNil(SessionServer.seen.first?.authorization)
        let refresh = await api.refreshToken
        XCTAssertNil(refresh)
        SessionServer.handle { _ in (500, Data()) }
        await api.revoke(refreshToken: "lrt_other")
        SessionServer.handle { _ in (SessionServer.offline, Data()) }
        await api.revoke(refreshToken: "lrt_other")
    }

    // MARK: - Renewal

    func testConcurrent401sShareOneRenewalAndRetryOnce() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60))
        SessionServer.handle { request in
            guard request.authorization == "Bearer new" else { return (401, SessionServer.unauthorized) }
            return (200, try! ApiFixtures.data(request.route == "/v1/account" ? "account" : "holdings"))
        }
        let renewals = Counter()
        await api.setRenewal {
            renewals.add()
            // Both requests are refused before the renewal ends.
            for _ in 0..<500 where SessionServer.seen.filter({ $0.authorization == "Bearer old" }).count < 2 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await api.restore(token: "new", expiresAt: Date().addingTimeInterval(3600))
        }
        async let account = api.account()
        async let holdings = api.holdings()
        let (a, h) = try await (account, holdings)
        XCTAssertEqual(a.view, "owner")
        XCTAssertEqual(h.address, a.address)
        XCTAssertEqual(renewals.count, 1)
        let seen = SessionServer.seen
        XCTAssertEqual(seen.count, 4)
        for route in ["/v1/account", "/v1/holdings"] {
            XCTAssertEqual(seen.filter { $0.route == route }.map(\.authorization), ["Bearer old", "Bearer new"], route)
        }
    }

    func testAViewerReadFallsBackToThePublicViewWhenRenewalFails() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60))
        await api.setViewer(address: signer.address)
        let renewals = Counter()
        await api.setRenewal {
            renewals.add()
            throw LiteAPIError.server(status: 401, code: "refresh_invalid", message: "Sign in again.")
        }
        let publicView = try ApiFixtures.data("account.public")
        let viewing = "/v1/account?address=\(signer.address)"
        SessionServer.handle { request in
            request.authorization == nil && request.route == viewing ? (200, publicView) : (401, SessionServer.unauthorized)
        }
        let account = try await api.account()
        XCTAssertEqual(account.view, "public")
        XCTAssertEqual(renewals.count, 1)
        XCTAssertEqual(SessionServer.seen.map(\.route), ["/v1/account", "/v1/account?address=\(signer.address)"])
        XCTAssertEqual(SessionServer.seen.map(\.authorization), ["Bearer old", nil])

        // The refused token is gone: the next viewer read asks for the public view straight away.
        let token = await api.token
        XCTAssertNil(token)
        SessionServer.reset(keepingHandler: true)
        _ = try await api.account()
        XCTAssertEqual(SessionServer.seen.map(\.authorization), [nil])
        XCTAssertEqual(renewals.count, 1)
    }

    func testASessionCallSaysNotSignedInWhenRenewalFails() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60))
        await api.setViewer(address: signer.address)
        await api.setRenewal { throw LiteAPIError.transport("offline") }
        SessionServer.handle { _ in (401, SessionServer.unauthorized) }
        do {
            _ = try await api.portfolio(period: .week)
            XCTFail("a refused session call returned")
        } catch let error as LiteAPIError {
            XCTAssertEqual(error, .notSignedIn)
        }
        XCTAssertEqual(SessionServer.seen.map(\.authorization), ["Bearer old"])
        SessionServer.reset(keepingHandler: true)
        do {
            _ = try await api.myMoments()
            XCTFail("a session call went out without a session")
        } catch LiteAPIError.notSignedIn {}
        XCTAssertEqual(SessionServer.seen.count, 0)
    }

    /// A renewed token the server refuses too: no second renewal, then the public view or `notSignedIn`.
    func testARenewedTokenRefusedAgainIsNotRenewedTwice() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60))
        await api.setViewer(address: signer.address)
        let renewals = Counter()
        await api.setRenewal {
            renewals.add()
            await api.restore(token: "new", expiresAt: Date().addingTimeInterval(3600))
        }
        let board = try ApiFixtures.data("launches")
        SessionServer.handle { request in request.authorization == nil ? (200, board) : (401, SessionServer.unauthorized) }
        _ = try await api.launchBoard(section: "explore", sort: "newest")
        XCTAssertEqual(SessionServer.seen.map(\.authorization), ["Bearer old", "Bearer new", nil])
        XCTAssertEqual(SessionServer.seen.last?.route, "/v1/launches?section=explore&sort=newest&address=\(signer.address)")
        XCTAssertEqual(renewals.count, 1)

        SessionServer.reset(keepingHandler: true)
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60))
        do {
            _ = try await api.activity()
            XCTFail("a refused session call returned")
        } catch LiteAPIError.notSignedIn {}
        XCTAssertEqual(SessionServer.seen.map(\.authorization), ["Bearer old", "Bearer new"])
        XCTAssertEqual(renewals.count, 2)
    }

    /// With no renewal set, a refused token is given up at once, as a failed renewal would be.
    func testWithoutARenewalA401GivesUpTheToken() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60))
        let board = try ApiFixtures.data("moments")
        SessionServer.handle { request in request.authorization == nil ? (200, board) : (401, SessionServer.unauthorized) }
        _ = try await api.moments()
        XCTAssertEqual(SessionServer.seen.map(\.authorization), ["Bearer old", nil])
        XCTAssertEqual(SessionServer.seen.map(\.route), ["/v1/moments", "/v1/moments"])
        let token = await api.token
        XCTAssertNil(token)
    }

    /// A restored session with no viewer set (as DyorLite restores one at launch): once its token is refused and can't
    /// be renewed, a read about the account says `notSignedIn` instead of asking about no one; a board still answers.
    func testWithoutAViewerAnAccountReadIsNotAskedAfterRenewalFails() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60))
        await api.setRenewal { throw LiteAPIError.server(status: 401, code: "refresh_invalid", message: "Sign in again.") }
        let addressRequired = try ApiFixtures.data("error-address-required")
        let board = try ApiFixtures.data("moments")
        SessionServer.handle { request in
            if request.authorization != nil { return (401, SessionServer.unauthorized) }
            return request.route == "/v1/moments" ? (200, board) : (400, addressRequired)
        }
        do {
            _ = try await api.account()
            XCTFail("an account read without a session or a viewer returned")
        } catch let error as LiteAPIError {
            XCTAssertEqual(error, .notSignedIn)
        }
        XCTAssertEqual(SessionServer.seen.map(\.route), ["/v1/account"])
        XCTAssertEqual(SessionServer.seen.map(\.authorization), ["Bearer old"])

        SessionServer.reset(keepingHandler: true)
        _ = try await api.moments()
        do {
            _ = try await api.earnPositions()
            XCTFail("an Earn read without a session or a viewer returned")
        } catch LiteAPIError.notSignedIn {}
        XCTAssertEqual(SessionServer.seen.map(\.route), ["/v1/moments"])
        XCTAssertEqual(SessionServer.seen.map(\.authorization), [nil])
    }

    /// Only a 401 renews: any other refusal of a session's request is the answer.
    func testOtherRefusalsAreNotRenewed() async throws {
        let api = api()
        await api.restore(token: "old", expiresAt: Date().addingTimeInterval(60))
        let renewals = Counter()
        await api.setRenewal { renewals.add() }
        let revoked = Data(#"{"error":{"code":"access_revoked","message":"Access to Stellar was turned off for this account."}}"#.utf8)
        SessionServer.handle { _ in (403, revoked) }
        do {
            _ = try await api.account()
            XCTFail("a refused read returned")
        } catch let error as LiteAPIError {
            XCTAssertEqual(error.code, "access_revoked")
        }
        XCTAssertEqual(renewals.count, 0)
        XCTAssertEqual(SessionServer.seen.count, 1)
        let token = await api.token
        XCTAssertEqual(token, "old")
    }
}

/// A count shared with `@Sendable` closures.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Answers each request through a handler (by route and token), and keeps every request it saw.
final class SessionServer: URLProtocol {
    struct Seen: Sendable {
        /// The path below the API's base, with its query: "/v1/account?address=G…".
        let route: String
        let authorization: String?
        let body: Data?

        var json: [String: String]? { body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } }
    }

    typealias Handler = @Sendable (Seen) -> (status: Int, body: Data)

    /// A status that fails the request as if offline.
    static let offline = 0
    static let unauthorized = Data(#"{"error":{"code":"unauthorized","message":"Your session expired. Sign in again."}}"#.utf8)

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var log: [Seen] = []

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionServer.self]
        return URLSession(configuration: config)
    }()

    static func reset(keepingHandler: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        log = []
        if !keepingHandler { handler = nil }
    }

    static func handle(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    static var seen: [Seen] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path.replacingOccurrences(of: "/functions/v1/lite", with: "")
        let seen = Seen(route: path + (url.query.map { "?" + $0 } ?? ""), authorization: request.value(forHTTPHeaderField: "authorization"), body: Self.body(of: request))
        Self.lock.lock()
        Self.log.append(seen)
        let handler = Self.handler
        Self.lock.unlock()
        let (status, body) = handler?(seen) ?? (500, Data())
        guard status != Self.offline else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The body as sent: URLSession hands it to a protocol as a stream.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
