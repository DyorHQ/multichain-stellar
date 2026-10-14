import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// SHA-256 for the SEP-53 self-check: CryptoKit on Apple platforms, swift-crypto (StellarCore's) elsewhere.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import StellarCore

public enum LiteAPIError: Error, Equatable, LocalizedError {
    /// The API refused: its code (`not_invited`, `not_enough_xlm_for_fee`, …) and plain-language message. When a
    /// contract refused (`simulation_failed` naming one), the code is the contract's stable code (`launch.slippage`,
    /// `moment.sold_out`, …), so the app can word it. `detail` holds the facts the refusal carries, as text (`need`,
    /// `spendable`, `minBalance`, `fee`, `max`, `asset`, `assetCode`, `minPrice`, `quoteCode`, …: every value its copy
    /// shows); nil when it carries none.
    case server(status: Int, code: String, message: String, detail: [String: String]? = nil)
    /// No session for a call that needs one, or the session ended and couldn't be renewed.
    case notSignedIn
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .server(_, _, let message, _): return message
        case .notSignedIn: return "Sign in on Stellar to continue."
        case .transport: return "DyorHQ on Stellar isn't reachable right now. Check your connection and try again."
        case .decoding(let what): return "Couldn't read \(what) from the server."
        }
    }

    public var code: String? {
        if case let .server(_, code, _, _) = self { return code }
        return nil
    }

    /// A refusal's facts (`server`'s `detail`).
    public var detail: [String: String]? {
        if case let .server(_, _, _, detail) = self { return detail }
        return nil
    }
}

/// The Lite API (`/functions/v1/lite/v1/…`). One instance per Stellar account.
///
/// Each route belongs to one of three classes (docs/API-lite.md §0). Public routes never carry the session token,
/// except the four today's server still guards (`Access.publicPending`). Viewer routes (the account's balances,
/// positions and editions, the boards, a launch or a Moment, asset search) carry it when one is held, and otherwise ask
/// for the public view of `viewerAddress`: on-chain facts only, DyorHQ's own history left null. A route about an
/// account isn't asked at all without a session or a viewer (`notSignedIn`). Session routes (history, plans, every
/// write) need the token. When a request that carried it is refused with 401, the renewal set with `setRenewal(_:)`
/// runs once, shared by every request it refused, and the request is tried once more; when that fails too, the token
/// is dropped, a viewer request is answered with the public view and a session request throws `notSignedIn`. The
/// token goes before any public view is asked for, so `token` says which view the reads answer, the lists included.
public actor LiteAPI {
    /// Who a request is for (`LiteAPI`'s three route classes).
    enum Access: Sendable, Equatable {
        /// Never the token.
        case `public`
        /// A public route today's server still guards: `prices`, `economics` and Earn's `markets` and `history` (the
        /// contract makes them public; WP-13, WP-14 and WP-15 serve them so). The token when one is held, and nothing
        /// else. A public route ignores the token, so this stays right until they become `public` here too.
        case publicPending
        /// The token when one is held, otherwise the public view of `viewerAddress`. `aboutAccount`: the answer is
        /// about an account (the account, its holdings, Earn positions or editions), so with no viewer either it isn't
        /// asked (`notSignedIn`; the server would refuse it with 400 `address_required`). A board or a page asks
        /// without one.
        case viewer(aboutAccount: Bool)
        /// The token, or `notSignedIn`.
        case session
    }

    public let baseURL: URL
    /// The pinned network's name ("testnet"): the only network a sign-in challenge may name. Nil accepts any.
    public let network: String?
    private let session: URLSession
    public private(set) var token: String?
    public private(set) var tokenExpiry: Date?
    /// The refresh token of the last sign-in or refresh (single use: each refresh hands out its successor), and when
    /// it lapses.
    public private(set) var refreshToken: String?
    public private(set) var refreshExpiry: Date?
    /// The account viewer routes ask about while no session is held. A sign-in or a refresh sets it to its account.
    public private(set) var viewerAddress: String?
    /// Renews the session after a 401 (`setRenewal(_:)`), and the renewal running now.
    private var renewal: (@Sendable () async throws -> Void)?
    private var renewing: Task<Void, Error>?
    /// The refreshes running now, by the refresh token each presents, and the refresh tokens already rotated here: a
    /// refresh token is single use, and presenting one twice ends its whole family (`refresh(address:refreshToken:)`).
    private var refreshing: [String: Task<AuthResult, Error>] = [:]
    private var spent: Set<String> = []

    public init(baseURL: URL, network: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.network = network
        self.session = session
    }

    public var isSignedIn: Bool { token != nil && (tokenExpiry ?? .distantPast) > Date().addingTimeInterval(60) }

    /// A saved session, as the last sign-in or refresh left it. The viewer stays as `setViewer(address:)` left it.
    public func restore(token: String, expiresAt: Date, refreshToken: String? = nil, refreshExpiresAt: Date? = nil) {
        self.token = token
        tokenExpiry = expiresAt
        self.refreshToken = refreshToken
        refreshExpiry = refreshExpiresAt
    }

    /// Forgets the session here (the server's side: `revoke(refreshToken:)`). The viewer stays.
    public func signOut() {
        token = nil
        tokenExpiry = nil
        refreshToken = nil
        refreshExpiry = nil
    }

    /// The account viewer routes ask about while no session is held; nil asks about none (the boards still answer; an
    /// account's own reads throw `notSignedIn` without asking).
    public func setViewer(address: String?) {
        viewerAddress = address
    }

    /// What renews the session when a request that carried the token is refused with 401: typically `refresh` with the
    /// refresh token this API holds (`refreshToken`), then a silent sign-in. It runs once for every request refused
    /// meanwhile, and should set a new token (`refresh`, `signIn`, `restore`) or throw. It must make no other call
    /// through this API: a request refused while it runs would wait for it. A renewal before expiry may call `refresh`
    /// at the same time: the two share one rotation.
    public func setRenewal(_ renew: (@Sendable () async throws -> Void)?) {
        renewal = renew
    }

    // ---------------------------------------------------------------------------------------------- auth

    /// Signs in with the account's Stellar key: `sign` signs the server's single-use challenge as a SEP-53 message and
    /// returns the signature in base64 (`StellarSigner.signMessage`). `sign` is asked only when the challenge is
    /// exactly the sign-in message for `network`, `address` and the challenge's own nonce (`isSignInChallenge`);
    /// anything else throws `.decoding("the sign-in challenge")` before it is called. Its signature is checked here as
    /// `address`'s SEP-53 signature of that message before it is sent (`.decoding("the sign-in signature")`
    /// otherwise), so nothing signed any other way leaves the phone. A first sign-in needs an invite code where the
    /// config says `inviteRequired`. `timeout` bounds each of the two requests (the challenge, then the verification).
    /// The session kept is the answer's, and `address` becomes the viewer.
    public func signIn(address: String, inviteCode: String? = nil, timeout: TimeInterval = 60, sign: @Sendable (String) async throws -> String) async throws -> AuthResult {
        let challenge: AuthChallenge = try await request("POST", "auth/challenge", body: ["address": address], access: .public, timeout: timeout)
        guard Self.isSignInChallenge(challenge.message, network: network, address: address, nonce: challenge.nonce) else {
            throw LiteAPIError.decoding("the sign-in challenge")
        }
        let signature = try await sign(challenge.message)
        guard StellarSigner.verifyMessage(challenge.message, signature: signature, address: address) else {
            throw LiteAPIError.decoding("the sign-in signature")
        }
        var body = ["address": address, "nonce": challenge.nonce, "signature": signature]
        if let inviteCode, !inviteCode.isEmpty { body["inviteCode"] = inviteCode }
        let result: AuthResult = try await request("POST", "auth/verify", body: body, access: .public, timeout: timeout)
        keep(result, address: address)
        return result
    }

    /// `signIn(address:inviteCode:timeout:sign:)` with the account's own key.
    public func signIn(signer: StellarSigner, inviteCode: String? = nil, timeout: TimeInterval = 60) async throws -> AuthResult {
        try await signIn(address: signer.address, inviteCode: inviteCode, timeout: timeout) { message in try signer.signMessage(message) }
    }

    /// Renews the session with a refresh token, which is single use: the answer carries a new session and its successor,
    /// kept as a sign-in's are. A refresh token that was already used ends its whole family (401 `refresh_reused`); one
    /// that is unknown, expired or revoked is refused with 401 `refresh_invalid`. Either way it is dropped here too.
    ///
    /// So that two renewals (one before expiry, one after a 401) can't end the session between them, no refresh token
    /// is presented twice from here: refreshes of one token at the same time share its one request and answer, and a
    /// token already rotated here is replaced by the one this API holds now (`notSignedIn` when it holds none).
    public func refresh(address: String, refreshToken: String, timeout: TimeInterval = 60) async throws -> AuthResult {
        let current = spent.contains(refreshToken) ? self.refreshToken : refreshToken
        guard let presented = current, !spent.contains(presented) else { throw LiteAPIError.notSignedIn }
        if let running = refreshing[presented] { return try await running.value }
        let rotation = Task { try await rotate(address: address, refreshToken: presented, timeout: timeout) }
        refreshing[presented] = rotation
        defer { refreshing[presented] = nil }
        return try await rotation.value
    }

    /// One `auth/refresh`: its session kept, and `refreshToken` spent.
    private func rotate(address: String, refreshToken: String, timeout: TimeInterval) async throws -> AuthResult {
        do {
            let result: AuthResult = try await request("POST", "auth/refresh", body: ["address": address, "refreshToken": refreshToken], access: .public, timeout: timeout)
            spent.insert(refreshToken)
            keep(result, address: address)
            return result
        } catch {
            if case LiteAPIError.server(401, _, _, _) = error, self.refreshToken == refreshToken {
                self.refreshToken = nil
                refreshExpiry = nil
            }
            throw error
        }
    }

    /// Ends `refreshToken`'s family on the server (`auth/signout`), as signing out and erasing the device do. Best
    /// effort: it never throws, and gives up after `timeout`.
    public func revoke(refreshToken: String, timeout: TimeInterval = 3) async {
        if self.refreshToken == refreshToken {
            self.refreshToken = nil
            refreshExpiry = nil
        }
        _ = try? await send("POST", "auth/signout", body: try? JSONEncoder().encode(["refreshToken": refreshToken]), access: .public, timeout: timeout)
    }

    /// A sign-in's or a refresh's session, and its account as the viewer.
    private func keep(_ result: AuthResult, address: String) {
        token = result.token
        tokenExpiry = ISO8601DateFormatter.lite.date(from: result.expiresAt)
        refreshToken = result.refreshToken
        refreshExpiry = result.refreshExpiresAt.flatMap(ISO8601DateFormatter.lite.date(from:))
        viewerAddress = address
    }

    /// Whether `message` is exactly the sign-in challenge (auth.ts `challengeMessage`) for `address`, at most 512 bytes:
    ///
    ///     DyorHQ Lite sign-in
    ///     Network: <network>
    ///     Address: <address>
    ///     Nonce: <nonce>
    ///     Issued: <an ISO 8601 time>
    ///
    /// `nonce` is the challenge's own, 16 to 64 of A–Z, a–z, 0–9, `_` and `-`. `network` is the pinned one; with none
    /// pinned, any name of 1 to 32 such characters. The time isn't compared with the clock, so a wrong clock never
    /// blocks a sign-in. Another network, address or nonce, another line or a missing one, and the message is refused.
    static func isSignInChallenge(_ message: String, network: String?, address: String, nonce: String) -> Bool {
        let lines = message.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard message.utf8.count <= 512, lines.count == 5, isName(nonce, length: 16...64),
              lines[1].hasPrefix("Network: "), lines[4].hasPrefix("Issued: ") else { return false }
        let named = String(lines[1].dropFirst("Network: ".count))
        let issued = String(lines[4].dropFirst("Issued: ".count))
        guard network != nil || isName(named, length: 1...32), isTimestamp(issued) else { return false }
        let expected = ["DyorHQ Lite sign-in", "Network: \(network ?? named)", "Address: \(address)", "Nonce: \(nonce)", "Issued: \(issued)"]
        return message.utf8.elementsEqual(expected.joined(separator: "\n").utf8)
    }

    /// `length` ASCII letters, digits, `_` and `-`.
    private static func isName(_ text: String, length: ClosedRange<Int>) -> Bool {
        length.contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"): return true
            default: return false
            }
        }
    }

    /// "2026-10-14T09:41:00.000Z": a date and a time to the second, up to 9 digits of fraction, then Z or an offset.
    private static func isTimestamp(_ text: String) -> Bool {
        guard let shape = try? Regex(#"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})"#),
              text.wholeMatch(of: shape.matchingSemantics(.unicodeScalar)) != nil else { return false }
        return (ISO8601DateFormatter.lite.date(from: text) ?? ISO8601DateFormatter().date(from: text)) != nil
    }

    // ---------------------------------------------------------------------------------------------- endpoints

    /// `timeout`: how long a request may take before it fails as offline; reads made while someone waits pass less.
    public func config(timeout: TimeInterval = 60) async throws -> LiteConfig { try await request("GET", "config", access: .public, timeout: timeout) }
    /// Public, like `config` and the markets: none of them reads anything about the user.
    public func fees(timeout: TimeInterval = 60) async throws -> StellarFees { try await request("GET", "fees", access: .public, timeout: timeout) }
    /// A viewer read about the account: the session's, or the public view of the viewer's (`view` says which).
    public func account(timeout: TimeInterval = 60) async throws -> AccountView { try await request("GET", "account", access: .viewer(aboutAccount: true), timeout: timeout) }
    /// A viewer read, like `account`.
    public func holdings(timeout: TimeInterval = 60) async throws -> StellarHoldings { try await request("GET", "holdings", access: .viewer(aboutAccount: true), timeout: timeout) }
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

    /// Top Tokens, in Popular order. Public: no session needed.
    public func markets(timeout: TimeInterval = 60) async throws -> StellarMarkets {
        try await request("GET", "markets", access: .public, timeout: timeout)
    }

    /// A token page: a registry id ("XLM") or a launch token's contract. Public.
    public func market(_ id: String) async throws -> StellarMarketDetail { try await request("GET", "markets/\(Self.segment(id))", access: .public) }

    /// A token's USD price over a period. Public.
    public func marketHistory(_ id: String, range: VolumePeriodKey) async throws -> StellarPriceHistory {
        try await request("GET", Self.path("markets/\(Self.segment(id))/history", ["range": range.rawValue]), access: .public)
    }

    /// Search by code or name, or exactly by a C… id or `CODE:G…`. A viewer read: `held` is about the session's
    /// account, or the viewer's.
    public func searchAssets(_ query: String) async throws -> [StellarAssetResult] {
        struct R: Decodable { let results: [StellarAssetResult] }
        let r: R = try await request("GET", Self.path("assets", ["q": query]), access: .viewer(aboutAccount: false))
        return r.results
    }

    public func portfolio(period: VolumePeriodKey) async throws -> StellarPortfolio {
        try await request("GET", Self.path("portfolio", ["period": period.rawValue]))
    }

    /// Public (the session goes along while the server still asks for one: `Access.publicPending`).
    public func earnMarkets() async throws -> [EarnMarket] {
        struct R: Decodable { let markets: [EarnMarket] }
        let r: R = try await request("GET", "earn/markets", access: .publicPending)
        return r.markets
    }

    /// A viewer read about the account. In the public view `deposited`, `withdrawn` and `earned` are nil (DyorHQ's
    /// history).
    public func earnPositions() async throws -> [EarnPosition] {
        struct R: Decodable { let positions: [EarnPosition] }
        let r: R = try await request("GET", "earn/positions", access: .viewer(aboutAccount: true))
        return r.positions
    }

    /// `range`: `.week` or `.month`. Public, like `earnMarkets`.
    public func earnHistory(pool: String, asset: String, range: VolumePeriodKey) async throws -> StellarEarnHistory {
        try await request("GET", Self.path("earn/history", ["pool": pool, "asset": asset, "range": range.rawValue]), access: .publicPending)
    }

    public func buildEarn(deposit: Bool, pool: String, asset: String, amount: Int64) async throws -> PlanView {
        try await request("POST", "earn/build", body: ["action": deposit ? "deposit" : "withdraw", "pool": pool, "asset": asset, "amount": String(amount)])
    }

    /// A viewer read, like the board.
    public func launches(sort: String) async throws -> [StellarLaunch] {
        struct R: Decodable { let launches: [StellarLaunch] }
        let r: R = try await request("GET", Self.path("launches", ["sort": sort]), access: .viewer(aboutAccount: false))
        return r.launches
    }

    /// A page of the board. `section`: "explore" or "graduated"; `sort`: "newest", "market_cap" or "near_graduation";
    /// `query` searches names and tickers; `cursor` is the previous page's `nextCursor`. A viewer read.
    public func launchBoard(section: String, sort: String, query: String? = nil, limit: Int? = nil, cursor: String? = nil) async throws -> StellarLaunchBoard {
        try await request("GET", Self.path("launches", ["section": section, "sort": sort, "q": query, "limit": limit.map(String.init), "cursor": cursor]), access: .viewer(aboutAccount: false))
    }

    /// A viewer read. In the public view `you` has no cost basis or P&L, and is nil without a viewer.
    public func launch(_ token: String, candles: String? = "5m") async throws -> StellarLaunchDetail {
        try await request("GET", Self.path("launches/\(Self.segment(token))", ["candles": candles]), access: .viewer(aboutAccount: false))
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

    /// The launchpad's and the Moments contract's terms, read live from the contracts. Public, like `earnMarkets`.
    public func economics() async throws -> StellarEconomics { try await request("GET", "economics", access: .publicPending) }

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

    /// `filter`: "all", "collecting" or "closed"; nil asks for the server's default (all). A viewer read.
    public func moments(filter: String? = nil, limit: Int? = nil) async throws -> [StellarMoment] {
        struct R: Decodable { let moments: [StellarMoment] }
        let r: R = try await request("GET", Self.path("moments", ["filter": filter, "limit": limit.map(String.init)]), access: .viewer(aboutAccount: false))
        return r.moments
    }

    /// A viewer read. In the public view `you.spent` is nil, and `you` is nil without a viewer.
    public func moment(_ id: Int) async throws -> StellarMomentDetail { try await request("GET", "moments/\(id)", access: .viewer(aboutAccount: false)) }

    /// A viewer read about the account: the session's editions, or the viewer's.
    public func ownedEditions() async throws -> [StellarEdition] {
        struct R: Decodable { let editions: [StellarEdition] }
        let r: R = try await request("GET", "moments/owned", access: .viewer(aboutAccount: true))
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

    /// Public, like `earnMarkets`.
    public func prices() async throws -> StellarPrices { try await request("GET", "prices", access: .publicPending) }

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

            /// The detail's facts as text: strings as they are, numbers and booleans written out; nil when there are none.
            var facts: [String: String]? {
                guard case let .object(fields)? = detail else { return nil }
                let facts = fields.compactMapValues { value -> String? in
                    switch value {
                    case .string(let text): return text
                    case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
                    case .bool(let b): return b ? "true" : "false"
                    case .array, .object, .null: return nil
                    }
                }
                return facts.isEmpty ? nil : facts
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

    func request<T: Decodable>(_ method: String, _ path: String, access: Access = .session, timeout: TimeInterval = 60) async throws -> T {
        try await request(method, path, body: Optional<[String: String]>.none, access: access, timeout: timeout)
    }

    func request<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?, access: Access = .session, timeout: TimeInterval = 60) async throws -> T {
        let data = try await send(method, path, body: try body.map { try JSONEncoder().encode($0) }, access: access, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LiteAPIError.decoding("\(T.self)")
        }
    }

    /// One call, as its route's class has it (`Access`); the body of its answer.
    func send(_ method: String, _ path: String, body: Data?, access: Access, timeout: TimeInterval) async throws -> Data {
        guard access != .public, let sent = token else {
            return try await exchange(method, try withoutSession(path, access), body: body, token: nil, timeout: timeout)
        }
        let (data, status) = try await answer(method, path, body: body, token: sent, timeout: timeout)
        if status != 401 { return try Self.accepted(data, status: status) }
        // The token was refused: one renewal for every request it refused, then this request once more.
        if await renewed(after: sent), let fresh = token {
            let (data, status) = try await answer(method, path, body: body, token: fresh, timeout: timeout)
            if status != 401 { return try Self.accepted(data, status: status) }
            drop(fresh)
        }
        return try await exchange(method, try withoutSession(path, access), body: body, token: nil, timeout: timeout)
    }

    /// Runs the renewal after `refused` was refused, once for every request it refused: a request refused while a
    /// renewal runs waits for that one, and one refused before an earlier renewal finished uses that renewal's token.
    /// True when a session is held after it.
    private func renewed(after refused: String) async -> Bool {
        let task: Task<Void, Error>
        if let renewing {
            task = renewing
        } else {
            guard token == refused else { return token != nil }
            guard let renewal else {
                drop(refused)
                return false
            }
            task = Task { try await renewal() }
            renewing = task
        }
        let done = (try? await task.value) != nil
        if renewing == task { renewing = nil }
        if !done { drop(refused) }
        return done && token != nil
    }

    /// Forgets a refused token nothing could renew, so viewer reads go straight to the public view and session calls
    /// throw `notSignedIn` without asking. A token renewed since is kept.
    private func drop(_ refused: String) {
        guard token == refused else { return }
        token = nil
        tokenExpiry = nil
    }

    /// A request's path without a session: a public route's as it is, a viewer route's asking for the public view of
    /// `viewerAddress` (a board's or a page's as it is when there is none). A session route, or one about an account
    /// with no viewer, isn't asked: `notSignedIn`.
    private func withoutSession(_ path: String, _ access: Access) throws -> String {
        switch access {
        case .public, .publicPending:
            return path
        case .viewer(let aboutAccount):
            guard let viewerAddress, let address = viewerAddress.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else {
                if aboutAccount { throw LiteAPIError.notSignedIn }
                return path
            }
            return path + (path.contains("?") ? "&" : "?") + "address=" + address
        case .session:
            throw LiteAPIError.notSignedIn
        }
    }

    /// One request; the answer's body as `accepted` reads it.
    private func exchange(_ method: String, _ path: String, body: Data?, token: String?, timeout: TimeInterval) async throws -> Data {
        let (data, status) = try await answer(method, path, body: body, token: token, timeout: timeout)
        return try Self.accepted(data, status: status)
    }

    /// One request, with `token` as its Bearer token when there is one; the answer's body and status, whatever it is.
    private func answer(_ method: String, _ path: String, body: Data?, token: String?, timeout: TimeInterval) async throws -> (Data, Int) {
        guard let url = URL(string: "v1/" + path, relativeTo: baseURL.appendingPathComponent("")) else { throw LiteAPIError.decoding("a URL") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = body
        }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        let (data, response) = try await perform(req)
        return (data, response.statusCode)
    }

    /// A 2xx answer's body; any other status thrown as the API's refusal.
    private static func accepted(_ data: Data, status: Int) throws -> Data {
        guard (200..<300).contains(status) else {
            if let e = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw LiteAPIError.server(status: status, code: e.error.contractCode ?? e.error.code, message: e.error.message, detail: e.error.facts)
            }
            throw LiteAPIError.server(status: status, code: "http_\(status)", message: "DyorHQ on Stellar answered \(status).")
        }
        return data
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

extension StellarSigner {
    /// Whether `signature` (base64) is `address`'s SEP-53 signature of `message`, as `signMessage` makes it: ed25519
    /// over sha256("Stellar Signed Message:\n" + message). A signature of the bare message, of another message or by
    /// another key isn't.
    public static func verifyMessage(_ message: String, signature: String, address: String) -> Bool {
        guard let raw = Data(base64Encoded: signature), raw.count == 64 else { return false }
        let digest = Array(SHA256.hash(data: Data(("Stellar Signed Message:\n" + message).utf8)))
        return verify(address: address, message: digest, signature: Array(raw))
    }
}

extension ISO8601DateFormatter {
    static let lite: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
