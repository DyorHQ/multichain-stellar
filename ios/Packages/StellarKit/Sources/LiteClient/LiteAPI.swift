import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StellarCore

public enum LiteAPIError: Error, Equatable, LocalizedError {
    /// The API refused: its code (`not_invited`, `budget_exhausted`, …) and plain-language message.
    case server(status: Int, code: String, message: String)
    case notSignedIn
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .server(_, _, let message): return message
        case .notSignedIn: return "Sign in on Stellar to continue."
        case .transport: return "DyorHQ on Stellar isn't reachable right now. Check your connection and try again."
        case .decoding(let what): return "Couldn't read \(what) from the server."
        }
    }

    public var code: String? {
        if case let .server(_, code, _) = self { return code }
        return nil
    }
}

/// The Lite API (`/functions/v1/lite/v1/…`). One instance per signed-in Stellar account.
public actor LiteAPI {
    public let baseURL: URL
    private let session: URLSession
    public private(set) var token: String?
    public private(set) var tokenExpiry: Date?

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public var isSignedIn: Bool { token != nil && (tokenExpiry ?? .distantPast) > Date().addingTimeInterval(60) }

    public func restore(token: String, expiresAt: Date) {
        self.token = token
        tokenExpiry = expiresAt
    }

    public func signOut() {
        token = nil
        tokenExpiry = nil
    }

    // ---------------------------------------------------------------------------------------------- auth

    /// Signs the single-use challenge with the account's Stellar key (SEP-53). A first sign-in needs an invite code.
    /// `timeout` bounds each of its two requests (the challenge, then the verification).
    public func signIn(signer: StellarSigner, inviteCode: String? = nil, timeout: TimeInterval = 60) async throws -> AuthResult {
        let challenge: AuthChallenge = try await request("POST", "auth/challenge", body: ["address": signer.address], authenticated: false, timeout: timeout)
        // The challenge's own first line (auth.ts challengeMessage): part of what is signed, so it never changes with the UI.
        let expected = "DyorHQ Lite sign-in\nNetwork: "
        guard challenge.message.hasPrefix(expected), challenge.message.contains("Address: \(signer.address)\n"), challenge.message.contains("Nonce: \(challenge.nonce)\n") else {
            throw LiteAPIError.decoding("the sign-in challenge")
        }
        var body = ["address": signer.address, "nonce": challenge.nonce, "signature": try signer.signMessage(challenge.message)]
        if let inviteCode, !inviteCode.isEmpty { body["inviteCode"] = inviteCode }
        let result: AuthResult = try await request("POST", "auth/verify", body: body, authenticated: false, timeout: timeout)
        token = result.token
        tokenExpiry = ISO8601DateFormatter.lite.date(from: result.expiresAt)
        return result
    }

    // ---------------------------------------------------------------------------------------------- endpoints

    /// `timeout`: how long a request may take before it fails as offline; reads made while someone waits pass less.
    public func config(timeout: TimeInterval = 60) async throws -> LiteConfig { try await request("GET", "config", authenticated: false, timeout: timeout) }
    public func account(timeout: TimeInterval = 60) async throws -> AccountView { try await request("GET", "account", timeout: timeout) }
    public func activate() async throws -> ActivationResult { try await request("POST", "account/activate", body: [String: String]()) }
    public func enable(asset: String) async throws -> PlanView { try await request("POST", "account/trust", body: ["asset": asset]) }
    public func faucet() async throws -> AnyJSON { try await request("POST", "account/faucet", body: [String: String]()) }

    /// `memoType`: "text", "id" or "hash" (SEP-24 withdrawals give both).
    public func send(asset: String, to: String, amount: Int64, memo: String? = nil, memoType: String? = nil) async throws -> PlanView {
        var body = ["asset": asset, "to": to, "amount": String(amount)]
        if let memo, !memo.isEmpty {
            body["memo"] = memo
            body["memoType"] = memoType ?? "text"
        }
        return try await request("POST", "send", body: body)
    }

    public func buildStep(planId: String, stepId: String) async throws -> PlanView {
        try await request("POST", "plans/\(planId)/steps/\(stepId)/build", body: [String: String]())
    }

    public func submit(planId: String, stepId: String, signedXdr: String) async throws -> TxStatus {
        try await request("POST", "tx/submit", body: ["planId": planId, "stepId": stepId, "signedXdr": signedXdr])
    }

    public func txStatus(_ hash: String) async throws -> TxStatus { try await request("GET", "tx/\(hash)") }

    public func quoteSwap(sell: String, buy: String, amount: Int64, slippageBps: Int) async throws -> SwapQuote {
        struct Body: Encodable { let sell: String; let buy: String; let amount: String; let slippageBps: Int }
        return try await request("POST", "swap/quote", body: Body(sell: sell, buy: buy, amount: String(amount), slippageBps: slippageBps))
    }

    public func buildSwap(quoteId: String) async throws -> PlanView { try await request("POST", "swap/build", body: ["quoteId": quoteId]) }

    public func earnMarkets() async throws -> [EarnMarket] {
        struct R: Decodable { let markets: [EarnMarket] }
        let r: R = try await request("GET", "earn/markets")
        return r.markets
    }

    public func earnPositions() async throws -> [EarnPosition] {
        struct R: Decodable { let positions: [EarnPosition] }
        let r: R = try await request("GET", "earn/positions")
        return r.positions
    }

    public func buildEarn(deposit: Bool, pool: String, asset: String, amount: Int64) async throws -> PlanView {
        try await request("POST", "earn/build", body: ["action": deposit ? "deposit" : "withdraw", "pool": pool, "asset": asset, "amount": String(amount)])
    }

    public func launches(sort: String) async throws -> [Launch] {
        struct R: Decodable { let launches: [Launch] }
        let r: R = try await request("GET", "launches?sort=\(sort)")
        return r.launches
    }

    public func launch(_ token: String, candles: String? = "5m") async throws -> LaunchDetail {
        try await request("GET", "launches/\(token)" + (candles.map { "?candles=\($0)" } ?? ""))
    }

    public func quoteTrade(token: String, buy: Bool, amount: Int64) async throws -> TradeQuote {
        try await request("POST", "launches/\(token)/quote", body: ["side": buy ? "buy" : "sell", "amount": String(amount)])
    }

    public struct LaunchRequest: Encodable, Sendable {
        public let action: String
        public var token: String?
        public var quote: String?
        public var name: String?
        public var symbol: String?
        public var uri: String?
        public var creatorFeeBps: Int?
        public var amount: String?
        public var minOut: String?

        public init(action: String, token: String? = nil, quote: String? = nil, name: String? = nil, symbol: String? = nil, uri: String? = nil, creatorFeeBps: Int? = nil, amount: String? = nil, minOut: String? = nil) {
            self.action = action
            self.token = token
            self.quote = quote
            self.name = name
            self.symbol = symbol
            self.uri = uri
            self.creatorFeeBps = creatorFeeBps
            self.amount = amount
            self.minOut = minOut
        }
    }

    public func buildLaunch(_ r: LaunchRequest) async throws -> PlanView { try await request("POST", "launches/build", body: r) }

    public func uploadTicket(contentType: String, bytes: Int) async throws -> UploadTicket {
        struct Body: Encodable { let contentType: String; let bytes: Int }
        return try await request("POST", "media/upload-url", body: Body(contentType: contentType, bytes: bytes))
    }

    /// PUTs the file to the one-time signed URL.
    public func upload(_ data: Data, contentType: String, to ticket: UploadTicket) async throws {
        guard let url = URL(string: ticket.uploadUrl) else { throw LiteAPIError.decoding("the upload URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "content-type")
        req.httpBody = data
        let (_, response) = try await perform(req)
        guard (200..<300).contains(response.statusCode) else { throw LiteAPIError.server(status: response.statusCode, code: "upload_failed", message: "The upload didn't finish. Try again.") }
    }

    public func moments() async throws -> [Moment] {
        struct R: Decodable { let moments: [Moment] }
        let r: R = try await request("GET", "moments")
        return r.moments
    }

    public func moment(_ id: Int) async throws -> MomentDetail { try await request("GET", "moments/\(id)") }

    public func ownedEditions() async throws -> [OwnedEdition] {
        struct R: Decodable { let editions: [OwnedEdition] }
        let r: R = try await request("GET", "moments/owned")
        return r.editions
    }

    public func momentMetadata(title: String, description: String, mediaUrl: String, video: Bool) async throws -> String {
        struct R: Decodable { let uri: String }
        let r: R = try await request("POST", "moments/metadata", body: ["title": title, "description": description, "mediaUrl": mediaUrl, "mediaType": video ? "video" : "image"])
        return r.uri
    }

    public func buildPublishMoment(uri: String, price: Int64, quote: String, maxEditions: Int, windowSecs: Int) async throws -> PlanView {
        struct Body: Encodable { let action = "publish"; let uri: String; let price: String; let quote: String; let maxEditions: Int; let windowSecs: Int }
        return try await request("POST", "moments/build", body: Body(uri: uri, price: String(price), quote: quote, maxEditions: maxEditions, windowSecs: windowSecs))
    }

    public func buildCollect(momentId: Int, quantity: Int) async throws -> PlanView {
        struct Body: Encodable { let action = "collect"; let momentId: Int; let quantity: Int }
        return try await request("POST", "moments/build", body: Body(momentId: momentId, quantity: quantity))
    }

    public func bridgeStart(toStellar: Bool, amount: String, monadAddress: String) async throws -> BridgeStart {
        try await request("POST", "bridge/start", body: ["direction": toStellar ? "monad_to_stellar" : "stellar_to_monad", "amount": amount, "monadAddress": monadAddress])
    }

    public func bridgeSource(id: String, txHash: String) async throws -> AnyJSON { try await request("POST", "bridge/\(id)/source", body: ["txHash": txHash]) }
    public func bridgeClaimed(id: String, txHash: String) async throws -> AnyJSON { try await request("POST", "bridge/\(id)/claimed", body: ["txHash": txHash]) }
    public func bridgeStatus(id: String) async throws -> BridgeStatus { try await request("GET", "bridge/\(id)") }

    public func anchors(country: String) async throws -> [AnchorInfo] {
        struct R: Decodable { let anchors: [AnchorInfo] }
        let r: R = try await request("GET", "cash/anchors?country=\(country)")
        return r.anchors
    }

    public func trackCash(anchor: String, deposit: Bool, asset: String, anchorTxId: String, status: String, amount: String?) async throws {
        var body = ["anchor": anchor, "kind": deposit ? "deposit" : "withdraw", "asset": asset, "anchorTxId": anchorTxId, "status": status]
        if let amount { body["amount"] = amount }
        let _: AnyJSON = try await request("POST", "cash/track", body: body)
    }

    public func activity() async throws -> [ActivityItem] {
        struct R: Decodable { let items: [ActivityItem] }
        let r: R = try await request("GET", "activity")
        return r.items
    }

    public func prices() async throws -> Prices { try await request("GET", "prices") }

    // ---------------------------------------------------------------------------------------------- transport

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let code: String; let message: String }
        let error: Inner
    }

    func request<T: Decodable>(_ method: String, _ path: String, authenticated: Bool = true, timeout: TimeInterval = 60) async throws -> T {
        try await request(method, path, body: Optional<[String: String]>.none, authenticated: authenticated, timeout: timeout)
    }

    func request<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?, authenticated: Bool = true, timeout: TimeInterval = 60) async throws -> T {
        guard let url = URL(string: "v1/" + path, relativeTo: baseURL.appendingPathComponent("")) else { throw LiteAPIError.decoding("a URL") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        if authenticated {
            guard let token else { throw LiteAPIError.notSignedIn }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        let (data, response) = try await perform(req)
        guard (200..<300).contains(response.statusCode) else {
            if let e = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                if response.statusCode == 401 { token = nil }
                throw LiteAPIError.server(status: response.statusCode, code: e.error.code, message: e.error.message)
            }
            throw LiteAPIError.server(status: response.statusCode, code: "http_\(response.statusCode)", message: "DyorHQ on Stellar answered \(response.statusCode).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LiteAPIError.decoding("\(T.self)")
        }
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: req) { data, response, error in
                if let error { return cont.resume(throwing: LiteAPIError.transport(error.localizedDescription)) }
                guard let http = response as? HTTPURLResponse else { return cont.resume(throwing: LiteAPIError.transport("no response")) }
                cont.resume(returning: (data ?? Data(), http))
            }.resume()
        }
    }
}

extension ISO8601DateFormatter {
    static let lite: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
