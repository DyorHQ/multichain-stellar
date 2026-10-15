@testable import DyorLite
import Foundation
import StellarKit
import XCTest

// The Lite API as the session and the store meet it in these tests: a fake server behind a URLProtocol (so the real
// `LiteAPI` runs: its renewal on a 401, its public view, its checks of the sign-in challenge), key providers that count
// every prompt and every Keychain read, and a plan runner that signs without a chain.

/// What the tests count: prompts (App Lock, a passkey ceremony) and reads of the Keychain's seed.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func add(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func callAsFunction(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }

    /// Every prompt the user would have seen: App Lock's Face ID, the passkey.
    var prompts: Int { self("appLock") + self("passkey") }
}

enum TestAccount {
    static let seed: [UInt8] = Array(repeating: 7, count: 32)
    static let seedSigner = try! StellarSigner(seed: seed)
    /// A SEP-5 phrase and its account, for passkey accounts (the passkey gives the phrase), made from fixed entropy as
    /// the tests run: the source holds no phrase.
    static let phrase = Mnemonic.phrase(entropy: Array(repeating: 0x5A, count: 16))!
    static let passkeyAddress = try! StellarDerivation.sep5(mnemonic: phrase).address

    /// A seed account's provider: the sign-in reads the seed with no prompt; an action asks App Lock once when
    /// `appLock` says it applies.
    static func seedKeys(appLock: Bool, tally: Tally) -> StoredSeedKeyProvider {
        StoredSeedKeyProvider(address: seedSigner.address, methodLabel: "Test", network: "testnet", appLock: { appLock },
                              seed: { tally.add("seedRead"); return seed },
                              authenticate: { _ in tally.add("appLock") })
    }

    /// A passkey account's provider: one passkey prompt per signature.
    static func passkeyKeys(tally: Tally) -> PhraseKeyProvider {
        PhraseKeyProvider(address: passkeyAddress, methodLabel: "Passkey") { _ in
            tally.add("passkey")
            return phrase
        }
    }

    /// A passkey account's setup ceremony: one passkey prompt.
    static func setupKey(tally: Tally, failing: Error? = nil) -> @Sendable (String) async throws -> LiteSession.UnlockResult {
        { _ in
            tally.add("passkey")
            tally.add("ceremony")
            if let failing { throw failing }
            return .init(keys: passkeyKeys(tally: tally), signer: try StellarDerivation.sep5(mnemonic: phrase))
        }
    }
}

/// The Lite API, stubbed: each request answered by the handler of its host, every request kept. Each test serves its own
/// host, so what an earlier test left running (a renewal timer, a refresh after a settle) never reaches its server.
final class StubServer: URLProtocol {
    struct Request: Sendable {
        let host: String
        let method: String
        /// The path below the API's base, with its query: "/v1/account?address=G…".
        let route: String
        let authorization: String?
        let body: Data?

        var path: String { String(route.split(separator: "?").first ?? Substring(route)) }
        var json: [String: String] { body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
        var token: String? { authorization.map { String($0.dropFirst("Bearer ".count)) } }
    }

    typealias Handler = @Sendable (Request) -> (status: Int, body: Data)

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private static var log: [Request] = []

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }()

    /// Forgets what `host` saw.
    static func reset(host: String) { lock.withLock { log.removeAll { $0.host == host } } }

    static func handle(host: String, _ handler: Handler?) { lock.withLock { handlers[host] = handler } }

    static func seen(host: String) -> [Request] { lock.withLock { log.filter { $0.host == host } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path.replacingOccurrences(of: "/lite", with: "")
        let seen = Request(host: url.host ?? "", method: request.httpMethod ?? "GET", route: path + (url.query.map { "?" + $0 } ?? ""),
                           authorization: request.value(forHTTPHeaderField: "authorization"), body: Self.body(of: request))
        let handler = Self.lock.withLock { () -> Handler? in
            Self.log.append(seen)
            return Self.handlers[seen.host]
        }
        let (status, body) = handler?(seen) ?? (500, Data())
        guard status != 0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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

/// A Lite server with real rules: sign-ins issue an access token and a refresh token; a refresh rotates its token, and
/// one used twice or unknown is refused; viewer routes answer the public view without a token; session routes and a
/// refused token get 401. Setup: activation creates the account and answers a plan to enable USDC.
final class FakeLite: @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()
    /// This server's own host.
    let host = "lite-\(UUID().uuidString.lowercased()).test"
    var base: URL { URL(string: "http://\(host)/lite")! }

    struct State {
        var enabled = true
        var minBuild = 1
        var sponsor = PinnedContracts.testnet.sponsor
        var exists = true
        var usdc = true
        /// Whether a sign-in without a code is let in (mainnet asks first-timers for one).
        var invited = true
        /// Access tokens and when each ends.
        var tokens: [String: Date] = [:]
        var refreshTokens: Set<String> = []
        var revoked: Set<String> = []
        var issued = 0
        var tokenLifetime: TimeInterval = 3600
        /// Paths answered as if offline.
        var offline: Set<String> = []
        /// Paths answered after a pause (seconds).
        var slow: [String: TimeInterval] = [:]
        /// A plan to answer `account/activate` with (else the account's own).
        var plan: String?
    }

    func update(_ change: (inout State) -> Void) { lock.withLock { change(&state) } }
    var current: State { lock.withLock { state } }

    /// Serves this fake through `StubServer`.
    func serve() {
        StubServer.handle(host: host) { [self] request in answer(request) }
    }

    /// Stops serving: what still runs from this test gets no answer.
    func stop() {
        StubServer.handle(host: host, nil)
        StubServer.reset(host: host)
    }

    /// What this server saw, and its paths ("POST /v1/auth/refresh"), in order.
    var seen: [StubServer.Request] { StubServer.seen(host: host) }
    var paths: [String] { seen.map { "\($0.method) \($0.path)" } }
    func forget() { StubServer.reset(host: host) }

    /// An API on this server, as the session makes it.
    func api() -> LiteAPI { LiteAPI(baseURL: base, network: "testnet", session: StubServer.session) }

    /// A session as a past sign-in left it, for the vault: valid on this server.
    func issueSession(lifetime: TimeInterval = 3600, refresh: Bool = true) -> LiteSavedSession {
        lock.withLock {
            state.issued += 1
            let token = "jwt\(state.issued)"
            let refreshToken = refresh ? "lrt_\(state.issued)" : nil
            state.tokens[token] = Date().addingTimeInterval(lifetime)
            if let refreshToken { state.refreshTokens.insert(refreshToken) }
            return LiteSavedSession(token: token, expiresAt: Date().addingTimeInterval(lifetime), refreshToken: refreshToken,
                                    refreshExpiresAt: refresh ? Date().addingTimeInterval(30 * 86_400) : nil)
        }
    }

    func answer(_ r: StubServer.Request) -> (status: Int, body: Data) {
        let s = current
        if let pause = s.slow[r.path] { Thread.sleep(forTimeInterval: pause) }
        if s.offline.contains(r.path) { return (0, Data()) }
        switch (r.method, r.path) {
        case ("GET", "/v1/config"): return (200, Self.config(enabled: s.enabled, minBuild: s.minBuild, sponsor: s.sponsor))
        case ("GET", "/v1/fees"): return (200, Self.fees)
        case ("POST", "/v1/auth/challenge"):
            let address = r.json["address"] ?? ""
            let message = ["DyorHQ Lite sign-in", "Network: testnet", "Address: \(address)", "Nonce: n0nce-\(String(repeating: "x", count: 16))",
                           "Issued: 2026-10-14T09:41:00.000Z"].joined(separator: "\n")
            return (200, Self.json(["nonce": "n0nce-\(String(repeating: "x", count: 16))", "message": message, "expiresAt": "2026-10-14T09:46:00.000Z"]))
        case ("POST", "/v1/auth/verify"):
            let code = r.json["inviteCode"]
            if !s.invited {
                guard let code else { return (403, Self.error("not_invited", "Enter your invite code.")) }
                guard code == "DYOR-GOOD" else { return (403, Self.error("bad_invite", "That code isn't valid.")) }
                update { $0.invited = true }
            }
            return (200, issue())
        case ("POST", "/v1/auth/refresh"):
            let presented = r.json["refreshToken"] ?? ""
            guard s.refreshTokens.contains(presented) else {
                return (401, Self.error(s.revoked.contains(presented) ? "refresh_reused" : "refresh_invalid", "Sign in again."))
            }
            update {
                $0.refreshTokens.remove(presented)
                $0.revoked.insert(presented)
            }
            return (200, issue())
        case ("POST", "/v1/auth/signout"):
            update {
                if let token = r.json["refreshToken"] {
                    $0.refreshTokens.remove(token)
                    $0.revoked.insert(token)
                }
            }
            return (204, Data())
        default:
            break
        }
        // Everything else: a token, when sent, must be good; viewer routes answer the public view without one.
        if let token = r.token, (s.tokens[token] ?? .distantPast) <= Date() { return (401, Self.error("unauthorized", "Your session expired. Sign in again.")) }
        let owner = r.token != nil
        switch (r.method, r.path) {
        case ("GET", "/v1/account"):
            guard owner || r.route.contains("address=") else { return (400, Self.error("address_required", "An address is required.")) }
            return (200, Self.account(exists: s.exists, usdc: s.usdc, view: owner ? "owner" : "public"))
        case ("GET", "/v1/holdings"):
            guard owner || r.route.contains("address=") else { return (400, Self.error("address_required", "An address is required.")) }
            return (200, Self.fixture(owner ? "holdings" : "holdings.public"))
        case ("GET", "/v1/earn/positions"): return (200, Self.fixture(owner ? "earn-positions" : "earn-positions.public"))
        case ("GET", "/v1/moments/owned"): return (200, Self.fixture(owner ? "moments-owned" : "moments-owned.public"))
        case ("GET", "/v1/earn/markets"): return (200, Self.fixture("earn-markets"))
        case ("GET", "/v1/prices"): return (200, Self.fixture("prices"))
        case ("GET", "/v1/launches"): return (200, Self.fixture("launches"))
        case ("GET", "/v1/moments"): return (200, Self.fixture("moments"))
        case ("GET", "/v1/markets"): return (200, Self.fixture("markets"))
        default: break
        }
        // Session routes.
        guard owner else { return (401, Self.error("unauthorized", "Sign in.")) }
        switch (r.method, r.path) {
        case ("GET", "/v1/activity"): return (200, Self.fixture("activity"))
        case ("GET", "/v1/portfolio"): return (200, Self.fixture("portfolio"))
        case ("POST", "/v1/account/activate"):
            if let plan = s.plan {
                update { $0.exists = true }
                return (200, Data(plan.utf8))
            }
            if s.exists && s.usdc { return (200, Self.json(["status": "active"], account: Self.account(exists: true, usdc: true, view: "owner"))) }
            update { $0.exists = true }
            return (200, Data(Self.plan(id: "setup", steps: [("s1", "trust", "Enable USDC", 10_000)]).utf8))
        case ("POST", "/v1/swap/quote"): return (200, Self.fixture("swap-quote"))
        case ("POST", "/v1/swap/build"): return (200, Data(Self.plan(id: "swap1", steps: [("s1", "trust", "Enable USDC", 10_000), ("s2", "swap_soroswap", "Swap", 400_000)]).utf8))
        default: return (404, Self.error("not_found", "No such route."))
        }
    }

    private func issue() -> Data {
        let (token, refresh, lifetime) = lock.withLock { () -> (String, String, TimeInterval) in
            state.issued += 1
            let token = "jwt\(state.issued)"
            let refresh = "lrt_\(state.issued)"
            state.tokens[token] = Date().addingTimeInterval(state.tokenLifetime)
            state.refreshTokens.insert(refresh)
            return (token, refresh, state.tokenLifetime)
        }
        let time = ISO8601DateFormatter.liteUI
        return Self.json(["token": token, "expiresAt": time.string(from: Date().addingTimeInterval(lifetime)), "refreshToken": refresh,
                          "refreshExpiresAt": time.string(from: Date().addingTimeInterval(30 * 86_400))], tester: true)
    }

    // MARK: Payloads

    static func json(_ fields: [String: String], tester: Bool = false, account: Data? = nil) -> Data {
        var object: [String: Any] = fields
        if tester { object["tester"] = ["address": "G", "label": NSNull()] }
        if let account { object["account"] = try! JSONSerialization.jsonObject(with: account) }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func error(_ code: String, _ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])
    }

    static func config(enabled: Bool = true, minBuild: Int = 1, sponsor: String = PinnedContracts.testnet.sponsor) -> Data {
        Data("""
        {"network":"testnet","passphrase":"Test SDF Network ; September 2015","rpcUrl":"http://127.0.0.1:9/rpc",
         "horizonUrl":"http://127.0.0.1:9/horizon","activation":"friendbot","sponsor":"\(sponsor)",
         "assets":[{"id":"XLM","code":"XLM","name":"Stellar Lumens","decimals":7,"contract":"CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC","classic":"native","note":null},
                   {"id":"USDC","code":"USDC","name":"USD Coin","decimals":7,"contract":"CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA","classic":"USDC:G","note":null}],
         "contracts":{"launchpad":null,"moments":null,"soroswapRouter":"C","blendPools":[]},"allowlist":{},"anchors":[],
         "bridge":{"routes":[],"monad":null},"flags":{"enabled":\(enabled)},"minBuild":\(minBuild),"inviteRequired":false,
         "faucet":{"amount":"10000"}}
        """.utf8)
    }

    static let fees = Data("""
    {"network":"testnet","baseReserve":"5000000","baseFee":"100","inclusionFee":{"classic":"100","soroban":"150"},
     "estimates":{"trust":"10000","swap_soroswap":"500000","payment":"10000"},"estimateBasis":{"trust":"default"},"updatedAt":null}
    """.utf8)

    /// An account with 10,000 XLM and one subentry (Friendbot, USDC enabled): 1.5 XLM kept, 9,998.5 spendable.
    static func account(exists: Bool, usdc: Bool, view: String) -> Data {
        let xlm = exists ? """
        {"balance":"100000000000","minBalance":"15000000","sellingLiabilities":"0","spendable":"99985000000","baseReserve":"5000000",
         "reserves":{"base":2,"subentries":1,"sponsoring":0,"sponsored":0}}
        """ : "null"
        return Data("""
        {"address":"G","exists":\(exists),"network":"testnet","activation":"friendbot","sponsor":"G","reserves":null,"view":"\(view)",
         "balances":[{"asset":"XLM","code":"XLM","name":"Stellar Lumens","contract":"CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC","classic":"native","decimals":7,"balance":"100000000000","enabled":true},
                     {"asset":"USDC","code":"USDC","name":"USD Coin","contract":"CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA","classic":"USDC:G","decimals":7,"balance":"52300000","enabled":\(usdc)}],
         "xlm":\(xlm)}
        """.utf8)
    }

    /// A plan whose steps the server hasn't built yet: each priced by its ceiling (`maxFee`).
    static func plan(id: String, steps: [(id: String, kind: String, label: String, maxFee: Int)]) -> String {
        let rows = steps.map { step in
            #"{"id":"\#(step.id)","label":"\#(step.label)","status":"pending","stepKind":"\#(step.kind)","maxFee":"\#(step.maxFee)","feePayer":"user","reserveDelta":\#(step.kind == "trust" ? 1 : 0)}"#
        }
        return #"{"planId":"\#(id)","kind":"\#(steps.last?.kind ?? "")","expiresAt":"2030-01-01T00:00:00.000Z","steps":[\#(rows.joined(separator: ","))]}"#
    }

    /// A payload from StellarKit's API fixtures (backend/tests/fixtures/api, synced there).
    static func fixture(_ name: String) -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // TestSupport.swift → DyorLiteTests → Tests → DyorLite → Packages
        url.appendPathComponent("StellarKit/Tests/LiteClientTests/Fixtures/\(name).json")
        return (try? Data(contentsOf: url)) ?? Data("{}".utf8)
    }
}

/// Runs plans without a chain: each step "signed" with the run's signer (checked to be the user's), the user's
/// signatures counted, and `afterRun` told (the fake server enables USDC once the setup plan has run).
final class TestBackend: LiteBackend, @unchecked Sendable {
    let api: LiteAPI
    private let lock = NSLock()
    private var runPlans: [String] = []
    private var signed = 0
    private var fees: PlanFees?
    var afterRun: (@Sendable (PlanView) -> Void)?
    /// A pause before each step's signature, to catch a run in the middle.
    var stepPause: TimeInterval = 0
    var failure: Error?

    init(api: LiteAPI) {
        self.api = api
    }

    var plans: [String] { lock.withLock { runPlans } }
    var signatures: Int { lock.withLock { signed } }
    /// The fees the last run was held to.
    var lastFees: PlanFees? { lock.withLock { fees } }

    func run(_ plan: PlanView, user: String, limits: [String: Int64], fees: PlanFees,
             signer: @Sendable () async throws -> StellarSigner, onEvent: @Sendable (PlanRunner.Event) -> Void) async throws -> [TxStatus] {
        lock.withLock {
            runPlans.append(plan.planId)
            self.fees = fees
        }
        if let failure { throw failure }
        var results: [TxStatus] = []
        for (index, step) in plan.steps.enumerated() {
            if step.xdr == nil { onEvent(.building(stepId: step.id, label: step.label)) }
            if stepPause > 0 { try await Task.sleep(for: .seconds(stepPause)) }
            onEvent(.signing(stepId: step.id, label: step.label))
            let key = try await signer()
            guard key.address == user else { throw PlanRunner.Failure.refused(step: step.label, reason: "wrong signing key") }
            lock.withLock { signed += 1 }
            let hash = String(repeating: String(index), count: 64)
            onEvent(.submitted(stepId: step.id, hash: hash))
            onEvent(.confirmed(stepId: step.id, hash: hash))
            results.append(try JSONDecoder().decode(TxStatus.self, from: Data(#"{"hash":"\#(hash)","status":"success"}"#.utf8)))
        }
        afterRun?(plan)
        return results
    }
}

final class MemoryVault: LiteSessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: LiteSavedSession] = [:]

    func load(account: String, network: String) -> LiteSavedSession? { lock.withLock { items["\(network).\(account)"] } }
    func save(_ session: LiteSavedSession, account: String, network: String) { lock.withLock { items["\(network).\(account)"] = session } }
    func erase(account: String, network: String) { lock.withLock { _ = items.removeValue(forKey: "\(network).\(account)") } }
}

extension XCTestCase {
    /// Waits until `condition` holds (at most `seconds`), on the main actor.
    @MainActor
    func waitUntil(_ seconds: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
