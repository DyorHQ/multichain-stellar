import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StellarCore

public enum LiteAPIError: Error, Equatable, LocalizedError {
    /// The API refused: its code (`not_invited`, `not_enough_xlm_for_fee`, …) and plain-language message. When a
    /// contract refused (`simulation_failed` naming one), the code is the contract's stable code (`launch.slippage`,
    /// `moment.sold_out`, …), so the app can word it.
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
    /// Public, like `config` and the markets: none of them reads anything about the user.
    public func fees(timeout: TimeInterval = 60) async throws -> StellarFees { try await request("GET", "fees", authenticated: false, timeout: timeout) }
    public func account(timeout: TimeInterval = 60) async throws -> AccountView { try await request("GET", "account", timeout: timeout) }
    public func holdings(timeout: TimeInterval = 60) async throws -> StellarHoldings { try await request("GET", "holdings", timeout: timeout) }
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

    /// Whether `address` can receive `asset` (a registry id or token contract) before a send is reviewed.
    public func recipient(_ address: String, asset: String) async throws -> StellarRecipient {
        try await request("GET", Self.path("recipient/\(Self.segment(address))", ["asset": asset]))
    }

    public func buildStep(planId: String, stepId: String) async throws -> PlanView {
        try await request("POST", "plans/\(Self.segment(planId))/steps/\(Self.segment(stepId))/build", body: [String: String]())
    }

    public func submit(planId: String, stepId: String, signedXdr: String) async throws -> TxStatus {
        try await request("POST", "tx/submit", body: ["planId": planId, "stepId": stepId, "signedXdr": signedXdr])
    }

    public func txStatus(_ hash: String) async throws -> TxStatus { try await request("GET", "tx/\(Self.segment(hash))") }

    public func quoteSwap(sell: String, buy: String, amount: Int64, slippageBps: Int) async throws -> SwapQuote {
        struct Body: Encodable { let sell: String; let buy: String; let amount: String; let slippageBps: Int }
        return try await request("POST", "swap/quote", body: Body(sell: sell, buy: buy, amount: String(amount), slippageBps: slippageBps))
    }

    /// `venue`: one of the quote's `routes` ("sdex", "soroswap", "aquarius"); nil builds the best.
    public func buildSwap(quoteId: String, venue: String? = nil) async throws -> PlanView {
        var body = ["quoteId": quoteId]
        if let venue { body["venue"] = venue }
        return try await request("POST", "swap/build", body: body)
    }

    /// Top Tokens, in Popular order. Public: it shows while the session is locked.
    public func markets(timeout: TimeInterval = 60) async throws -> StellarMarkets {
        try await request("GET", "markets", authenticated: false, timeout: timeout)
    }

    /// A token page: a registry id ("XLM") or a launch token's contract. Public.
    public func market(_ id: String) async throws -> StellarMarketDetail { try await request("GET", "markets/\(Self.segment(id))", authenticated: false) }

    /// A token's USD price over a period. Public.
    public func marketHistory(_ id: String, range: VolumePeriodKey) async throws -> StellarPriceHistory {
        try await request("GET", Self.path("markets/\(Self.segment(id))/history", ["range": range.rawValue]), authenticated: false)
    }

    /// Search by code or name, or exactly by a C… id or `CODE:G…`. Signed in, so results say what the user holds.
    public func searchAssets(_ query: String) async throws -> [StellarAssetResult] {
        struct R: Decodable { let results: [StellarAssetResult] }
        let r: R = try await request("GET", Self.path("assets", ["q": query]))
        return r.results
    }

    public func portfolio(period: VolumePeriodKey) async throws -> StellarPortfolio {
        try await request("GET", Self.path("portfolio", ["period": period.rawValue]))
    }

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

    /// `range`: `.week` or `.month`.
    public func earnHistory(pool: String, asset: String, range: VolumePeriodKey) async throws -> StellarEarnHistory {
        try await request("GET", Self.path("earn/history", ["pool": pool, "asset": asset, "range": range.rawValue]))
    }

    public func buildEarn(deposit: Bool, pool: String, asset: String, amount: Int64) async throws -> PlanView {
        try await request("POST", "earn/build", body: ["action": deposit ? "deposit" : "withdraw", "pool": pool, "asset": asset, "amount": String(amount)])
    }

    public func launches(sort: String) async throws -> [StellarLaunch] {
        struct R: Decodable { let launches: [StellarLaunch] }
        let r: R = try await request("GET", Self.path("launches", ["sort": sort]))
        return r.launches
    }

    /// A page of the board. `section`: "explore" or "graduated"; `sort`: "newest", "market_cap" or "near_graduation";
    /// `query` searches names and tickers; `cursor` is the previous page's `nextCursor`.
    public func launchBoard(section: String, sort: String, query: String? = nil, limit: Int? = nil, cursor: String? = nil) async throws -> StellarLaunchBoard {
        try await request("GET", Self.path("launches", ["section": section, "sort": sort, "q": query, "limit": limit.map(String.init), "cursor": cursor]))
    }

    public func launch(_ token: String, candles: String? = "5m") async throws -> StellarLaunchDetail {
        try await request("GET", Self.path("launches/\(Self.segment(token))", ["candles": candles]))
    }

    public func quoteTrade(token: String, buy: Bool, amount: Int64) async throws -> TradeQuote {
        try await request("POST", "launches/\(Self.segment(token))/quote", body: ["side": buy ? "buy" : "sell", "amount": String(amount)])
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

    /// Writes a coin's metadata (`imageUrl` from `uploadTicket`; links https) and returns the URI to launch it with.
    public func launchMetadata(name: String, symbol: String, description: String? = nil, imageUrl: String? = nil, website: String? = nil, x: String? = nil, telegram: String? = nil) async throws -> String {
        struct Body: Encodable { let name: String; let symbol: String; let description: String?; let imageUrl: String?; let website: String?; let x: String?; let telegram: String? }
        struct R: Decodable { let uri: String }
        let r: R = try await request("POST", "launches/metadata", body: Body(name: name, symbol: symbol, description: description, imageUrl: imageUrl, website: website, x: x, telegram: telegram))
        return r.uri
    }

    /// The launchpad's and the Moments contract's terms, read live from the contracts.
    public func economics() async throws -> StellarEconomics { try await request("GET", "economics") }

    public func myLaunchpad() async throws -> StellarMyLaunchpad { try await request("GET", "launchpad/me") }

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

    /// `filter`: "all", "collecting" or "closed"; nil asks for the server's default (all).
    public func moments(filter: String? = nil, limit: Int? = nil) async throws -> [StellarMoment] {
        struct R: Decodable { let moments: [StellarMoment] }
        let r: R = try await request("GET", Self.path("moments", ["filter": filter, "limit": limit.map(String.init)]))
        return r.moments
    }

    public func moment(_ id: Int) async throws -> StellarMomentDetail { try await request("GET", "moments/\(id)") }

    public func ownedEditions() async throws -> [StellarEdition] {
        struct R: Decodable { let editions: [StellarEdition] }
        let r: R = try await request("GET", "moments/owned")
        return r.editions
    }

    public func myMoments() async throws -> StellarMomentsMine { try await request("GET", "moments/mine") }

    public func momentMetadata(title: String, description: String, mediaUrl: String, video: Bool) async throws -> String {
        struct R: Decodable { let uri: String }
        let r: R = try await request("POST", "moments/metadata", body: ["title": title, "description": description, "mediaUrl": mediaUrl, "mediaType": video ? "video" : "image"])
        return r.uri
    }

    /// Writes a Moment's metadata and returns its URI and poster. `mediaType`: "image" or "video"; a video needs
    /// `posterUrl` (a frame the phone uploaded). `takenOn`: "2026-10-14".
    public func momentMetadata(title: String, description: String?, mediaUrl: String, mediaType: String, posterUrl: String?, place: String?, takenOn: String?) async throws -> (uri: String, posterUrl: String?) {
        struct Body: Encodable { let title: String; let description: String?; let mediaUrl: String; let mediaType: String; let posterUrl: String?; let place: String?; let takenOn: String? }
        struct R: Decodable { let uri: String; let posterUrl: String? }
        let r: R = try await request("POST", "moments/metadata", body: Body(title: title, description: description, mediaUrl: mediaUrl, mediaType: mediaType, posterUrl: posterUrl, place: place, takenOn: takenOn))
        return (r.uri, r.posterUrl)
    }

    public func buildPublishMoment(uri: String, price: Int64, quote: String, maxEditions: Int, windowSecs: Int) async throws -> PlanView {
        struct Body: Encodable { let action = "publish"; let uri: String; let price: String; let quote: String; let maxEditions: Int; let windowSecs: Int }
        return try await request("POST", "moments/build", body: Body(uri: uri, price: String(price), quote: quote, maxEditions: maxEditions, windowSecs: windowSecs))
    }

    public func buildCollect(momentId: Int, quantity: Int) async throws -> PlanView {
        struct Body: Encodable { let action = "collect"; let momentId: Int; let quantity: Int }
        return try await request("POST", "moments/build", body: Body(momentId: momentId, quantity: quantity))
    }

    /// `amount`: in the sending side's base units (6 decimals on Monad, 7 on Stellar).
    public func bridgeQuote(toStellar: Bool, amount: String) async throws -> StellarBridgeQuote {
        try await request("POST", "bridge/quote", body: ["direction": toStellar ? "monad_to_stellar" : "stellar_to_monad", "amount": amount])
    }

    public func bridgeStart(toStellar: Bool, amount: String, monadAddress: String) async throws -> BridgeStart {
        try await request("POST", "bridge/start", body: ["direction": toStellar ? "monad_to_stellar" : "stellar_to_monad", "amount": amount, "monadAddress": monadAddress])
    }

    public func bridgeSource(id: String, txHash: String) async throws -> AnyJSON { try await request("POST", "bridge/\(Self.segment(id))/source", body: ["txHash": txHash]) }
    public func bridgeClaimed(id: String, txHash: String) async throws -> AnyJSON { try await request("POST", "bridge/\(Self.segment(id))/claimed", body: ["txHash": txHash]) }
    public func bridgeStatus(id: String) async throws -> BridgeStatus { try await request("GET", "bridge/\(Self.segment(id))") }

    public func anchors(country: String) async throws -> [AnchorInfo] {
        struct R: Decodable { let anchors: [AnchorInfo] }
        let r: R = try await request("GET", Self.path("cash/anchors", ["country": country]))
        return r.anchors
    }

    public func trackCash(anchor: String, deposit: Bool, asset: String, anchorTxId: String, status: String, amount: String?) async throws {
        var body = ["anchor": anchor, "kind": deposit ? "deposit" : "withdraw", "asset": asset, "anchorTxId": anchorTxId, "status": status]
        if let amount { body["amount"] = amount }
        let _: AnyJSON = try await request("POST", "cash/track", body: body)
    }

    /// Every filter is optional: `section` ("spot", "earn", "launch", …), `kind` ("launch_buy", …), `market` (a token
    /// or an Earn market).
    public func activity(section: String? = nil, kind: String? = nil, period: VolumePeriodKey? = nil, market: String? = nil, limit: Int? = nil) async throws -> [StellarActivityItem] {
        struct R: Decodable { let items: [StellarActivityItem] }
        let r: R = try await request("GET", Self.path("activity", ["section": section, "kind": kind, "period": period?.rawValue, "market": market, "limit": limit.map(String.init)]))
        return r.items
    }

    public func prices() async throws -> StellarPrices { try await request("GET", "prices") }

    // ---------------------------------------------------------------------------------------------- transport

    private struct ErrorBody: Decodable {
        struct Inner: Decodable {
            let code: String
            let message: String
            /// Anything: `{contractCode}` when a contract refused, other facts otherwise.
            let detail: AnyJSON?

            var contractCode: String? {
                guard case let .object(fields)? = detail, case let .string(code)? = fields["contractCode"] else { return nil }
                return code
            }
        }

        let error: Inner
    }

    /// `path?name=value&…`, each value escaped; nil values are left out, the rest kept in order.
    static func path(_ path: String, _ query: KeyValuePairs<String, String?>) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let items = query.compactMap { name, value in
            value.flatMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }.map { "\(name)=\($0)" }
        }
        return items.isEmpty ? path : path + "?" + items.joined(separator: "&")
    }

    /// A value as one path segment: everything but ASCII letters, digits and `-._~` escaped, so a pasted address can't
    /// add a query, a fragment or segments of its own. Empty, or dots alone, it would name the route above, so it throws.
    static func segment(_ value: String) throws -> String {
        guard value.contains(where: { $0 != "." }), let escaped = value.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw LiteAPIError.decoding("a URL")
        }
        return escaped
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

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
                throw LiteAPIError.server(status: response.statusCode, code: e.error.contractCode ?? e.error.code, message: e.error.message)
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
