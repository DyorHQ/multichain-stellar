import Foundation

/* A small Supabase client for DyorHQ's backend: signs in by having the user's wallet personal_sign a single-use nonce
   the wallet-auth Edge Function issued (it verifies the signature, consumes the nonce and mints a session), then reads
   and writes tables over PostgREST.
   Public data reads with the publishable key alone; writes carry the wallet session token, and row-level security
   ties every row to the signed-in wallet. No private keys are ever sent — only a signature over a nonce. */

public struct SupabaseSession: Sendable, Codable, Equatable {
    public let accessToken: String
    public let wallet: String
    public let expiresAt: Date
    public var isValid: Bool { expiresAt > Date().addingTimeInterval(60) }
}

public enum SupabaseError: LocalizedError {
    case http(Int, String)
    case notSignedIn
    case decoding(String)
    /// wallet-auth refused a signed sign-in (401): the single-use nonce was invalid, expired or already used, or the
    /// signature didn't match. Carries the server's reason.
    case signInRejected(String)
    /// Too many attempts (429). `retryAfter` is the server's wait in seconds, when it sends one.
    case rateLimited(retryAfter: Int?)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            if code == 500, body.contains("APP_JWT_SECRET") { return L10n.tr("Sign-in isn't finished on the server yet (APP_JWT_SECRET not set).") }
            if (500...599).contains(code) { return L10n.tr("DyorHQ's server isn't answering right now (\(String(code))). Try again in a minute.") }
            return L10n.tr("Supabase request failed (\(String(code))).")
        case .notSignedIn: return L10n.tr("Sign in to DyorHQ to continue.")
        case .decoding(let what): return L10n.tr("Could not read \(what) from the server.")
        case .signInRejected(let reason):
            // not localized: the server's own English reason, matched as it sends it
            if reason.contains("nonce") { return L10n.tr("That sign-in expired or was already used. Please try again.") }
            return reason.isEmpty ? L10n.tr("Sign-in was refused. Please try again.") : L10n.tr("Sign-in was refused (\(reason)). Please try again.")
        case .rateLimited(let retryAfter):
            guard let seconds = retryAfter, seconds > 0 else { return L10n.tr("Too many attempts. Please wait a few minutes and try again.") }
            return L10n.tr("Too many attempts. Try again in \(String(max(1, (seconds + 59) / 60))) min.")
        }
    }

    /// Whether `error` only means the backend couldn't be reached or answered with a server error (5xx), as opposed
    /// to refusing the request: nothing the user typed was judged, so a password is not wrong because of it (GE-6).
    public static func isOutage(_ error: Error) -> Bool {
        if case .http(let code, _)? = error as? SupabaseError { return (500...599).contains(code) }
        guard let url = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                .dnsLookupFailed, .secureConnectionFailed, .dataNotAllowed, .internationalRoamingOff].contains(url.code)
    }
}

/// Why `email-pepper` wants this email proven before it answers (see `SupabaseClient.emailPepper`). Every case is
/// resolved the same way: run the email one-time-code flow, `rememberEmailProof` its Privy token, and try again.
public enum EmailPepperError: LocalizedError, Equatable {
    /// The email's anonymous budget is spent — possibly by someone else who knows the address — while the client
    /// network's limit is not. Its verified budget is separate, and a fresh one-time code opens it.
    case verificationRequired(retryAfter: Int?)
    /// The server refused the remembered proof (401: expired or invalid). It has been forgotten.
    case verificationExpired
    /// The remembered proof attests a different email than the one asked about (400). It has been forgotten.
    case verificationMismatch

    public var errorDescription: String? {
        switch self {
        case .verificationRequired: return L10n.tr("Too many attempts for this email. Verify your email to continue.")
        case .verificationExpired: return L10n.tr("Your email verification expired. Verify your email again to continue.")
        case .verificationMismatch: return L10n.tr("That verification was for a different email. Verify this email to continue.")
        }
    }
}

public actor SupabaseClient {
    public let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private var current: SupabaseSession?
    /// Privy access tokens from a fresh email one-time code, keyed by the email hash e they prove
    /// (`EmailWallet.emailHash`). Memory only, and only ever sent to `email-pepper` for that same e — never to any other
    /// function, table or host.
    private var emailProofs: [Data: String] = [:]

    public init(url: URL, anonKey: String, session: URLSession = .shared) {
        baseURL = url
        self.anonKey = anonKey
        self.session = session
    }

    public var currentSession: SupabaseSession? { current?.isValid == true ? current : nil }
    public var signedInWallet: String? { currentSession?.wallet }

    /// The URL of one of the project's Edge Functions.
    public nonisolated func functionURL(_ name: String) -> URL { baseURL.appending(path: "functions/v1/\(name)") }

    /// Opens the connection to the project before the first read needs it (speed work, 2026-10-10): a `HEAD` of its root,
    /// which carries no key, reads no table and changes nothing, its answer unread. A new connection cost 0.4–0.8 s of
    /// handshakes (measured 2026-10-08), paid by the app's first sign-in, settings and profile reads otherwise; every
    /// request of this client goes over the one it opens (the same session, the same host).
    public nonisolated func warm() async {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = RPCClient.readTimeout
        _ = try? await session.data(for: request)
    }

    /// Headers that authenticate a request to an Edge Function as the signed-in wallet (publishable key + session
    /// JWT). Throws when there is no valid session.
    public func sessionHeaders() throws -> [String: String] {
        guard let token = currentSession?.accessToken else { throw SupabaseError.notSignedIn }
        return ["apikey": anonKey, "Authorization": "Bearer \(token)"]
    }

    /// Reuse a stored session if it's still valid.
    public func restore(_ stored: SupabaseSession?) {
        current = (stored?.isValid == true) ? stored : nil
    }

    public func signOut() { current = nil }

    /// Signs out only while the session is the one holding `accessToken`: a sign-out that finishes after a newer
    /// sign-in has been adopted leaves that one alone (security audit 2026-09-26, RS-6).
    public func signOut(ifAccessToken accessToken: String) {
        if current?.accessToken == accessToken { current = nil }
    }

    /// Signs in: asks wallet-auth for a single-use nonce bound to this address, has the wallet sign the exact sign-in
    /// message around it, and exchanges the signature for a session. The server consumes the nonce on success, so a
    /// captured signature can never be replayed. `sign` is the wallet's `signMessage` (EIP-191 personal_sign).
    /// `adopt: false` returns the session without making it the client's: a caller that may have moved on to another
    /// wallet while this ran checks first, then `restore`s it.
    public func signIn(address: String, adopt: Bool = true, sign: (Data) async throws -> Data) async throws -> SupabaseSession {
        let nonce = try await signInNonce(address: address)
        // The message names the wallet with its EIP-55 checksum, whatever case the request carries.
        let message = Self.signInMessage(address: Address(address)?.checksummed ?? address, nonce: nonce,
                                         issuedAt: Int(Date().timeIntervalSince1970 * 1000))
        let signature = try await sign(Data(message.utf8)).hexString
        let body = try JSONSerialization.data(withJSONObject: ["address": address, "message": message, "signature": signature])
        let data = try await walletAuth(body)
        struct AuthResponse: Decodable { let access_token: String; let expires_in: Int; let wallet: String }
        guard let response = try? JSONDecoder().decode(AuthResponse.self, from: data) else { throw SupabaseError.decoding(L10n.string(LocalizedStringResource("the sign-in response", bundle: L10n.kit, comment: "What the app could not read, completing “Could not read <this> from the server.”"))) }
        let created = SupabaseSession(accessToken: response.access_token, wallet: response.wallet, expiresAt: Date().addingTimeInterval(Double(response.expires_in)))
        if adopt { current = created }
        return created
    }

    /// The exact EIP-4361 (Sign-In with Ethereum) message wallet-auth verifies (security audit 2026-09-26, IOSK-7): bound
    /// to DyorHQ's domain and to Monad, around the server's nonce, and valid for ten minutes from `issuedAt` (unix
    /// milliseconds). The server's parse is anchored, so not a byte may differ: `address` is the wallet with its EIP-55
    /// checksum, lines are separated by a single "\n", and there is no trailing newline.
    public static func signInMessage(address: String, nonce: String, issuedAt: Int) -> String {
        // not localized: the message the server parses, byte for byte, in every language
        [
            "\(signInDomain) wants you to sign in with your Ethereum account:",
            address,
            "",
            "Sign in to DyorHQ.",
            "",
            "URI: https://\(signInDomain)",
            "Version: 1",
            "Chain ID: \(signInChainId)",
            "Nonce: \(nonce)",
            "Issued At: \(iso8601(millis: issuedAt))",
            "Expiration Time: \(iso8601(millis: issuedAt + signInLifetimeMillis))",
        ].joined(separator: "\n")
    }

    /// The sign-in's fixed EIP-4361 fields: DyorHQ's domain, and Monad mainnet's chain id (143), which wallet-auth
    /// requires whatever RPC this build talks to.
    static let signInDomain = "dyorhq.fun"
    static let signInChainId = 143
    /// How long a signed sign-in stays valid (its Expiration Time); wallet-auth refuses anything longer.
    static let signInLifetimeMillis = 10 * 60 * 1000

    /// `millis` (unix milliseconds) as ISO-8601 UTC with milliseconds, "2026-09-26T12:34:56.789Z" — exactly what
    /// JavaScript's `Date.prototype.toISOString` prints, which wallet-auth compares against. Integer arithmetic on the
    /// milliseconds, so the digits never pick up a floating-point rounding.
    static func iso8601(millis: Int) -> String {
        let (seconds, milliseconds) = millis.quotientAndRemainder(dividingBy: 1000)
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, milliseconds)
    }

    /// The unix milliseconds of a timestamp in exactly `iso8601(millis:)`'s form, or nil: anything else, or a date that
    /// doesn't exist (it must print back unchanged).
    static func millis(iso8601 text: String) -> Int? {
        let chars = Array(text.utf8)
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 46, 23: 90] // - - T : : . Z
        guard chars.count == 24 else { return nil }
        for (i, byte) in chars.enumerated() {
            if let separator = separators[i] { guard byte == separator else { return nil } }
            else if !(48...57).contains(byte) { return nil }
        }
        func number(_ from: Int, _ length: Int) -> Int { Int(String(decoding: chars[from..<from + length], as: UTF8.self)) ?? -1 }
        let components = DateComponents(year: number(0, 4), month: number(5, 2), day: number(8, 2),
                                        hour: number(11, 2), minute: number(14, 2), second: number(17, 2))
        guard let date = utcCalendar.date(from: components) else { return nil }
        let millis = Int(date.timeIntervalSince1970) * 1000 + number(20, 3)
        return iso8601(millis: millis) == text ? millis : nil
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A fresh single-use nonce from wallet-auth (32 random bytes as 64 lowercase hex), bound to `address` for 5 minutes.
    private func signInNonce(address: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["action": "nonce", "address": address])
        let data = try await walletAuth(body)
        struct NonceResponse: Decodable { let nonce: String }
        guard let nonce = try? JSONDecoder().decode(NonceResponse.self, from: data).nonce, Self.isHex32Bytes(nonce) else {
            throw SupabaseError.decoding(L10n.string(LocalizedStringResource("the sign-in nonce", bundle: L10n.kit, comment: "What the app could not read, completing “Could not read <this> from the server.”")))
        }
        return nonce
    }

    /// POSTs to wallet-auth, turning its refusals into errors a person can act on.
    private func walletAuth(_ body: Data) async throws -> Data {
        do { return try await send(method: "POST", path: "functions/v1/wallet-auth", query: [], body: body, prefer: nil, authed: false) }
        catch SupabaseError.http(401, let text) { throw SupabaseError.signInRejected(Self.serverField(text, "error") as? String ?? "") }
        catch SupabaseError.http(429, let text) { throw SupabaseError.rateLimited(retryAfter: Self.retryAfter(text)) }
    }

    // MARK: PostgREST

    /// Reads rows from a table. `query` is the PostgREST query (select, filters, order, limit).
    public func read<T: Decodable>(_ table: String, query: [URLQueryItem] = [], authed: Bool = false) async throws -> [T] {
        let data = try await send(method: "GET", path: "rest/v1/\(table)", query: query, body: nil, prefer: nil, authed: authed)
        return try decode(data, as: [T].self)
    }

    /// Inserts or upserts a row, returning the stored representation. Requires a session.
    @discardableResult
    public func upsert<Body: Encodable, T: Decodable>(_ table: String, _ value: Body, onConflict: String? = nil, returning: T.Type = T.self) async throws -> T {
        guard currentSession != nil else { throw SupabaseError.notSignedIn }
        var query: [URLQueryItem] = []
        if let onConflict { query.append(URLQueryItem(name: "on_conflict", value: onConflict)) }
        let body = try JSONEncoder().encode(value)
        let data = try await send(method: "POST", path: "rest/v1/\(table)", query: query, body: body, prefer: "return=representation,resolution=merge-duplicates", authed: true)
        let rows = try decode(data, as: [T].self)
        guard let first = rows.first else { throw SupabaseError.decoding(table) }
        return first
    }

    /// Upserts many rows in one request (no representation returned). Requires a session.
    public func upsertRows<Body: Encodable>(_ table: String, _ rows: [Body], onConflict: String? = nil) async throws {
        guard currentSession != nil else { throw SupabaseError.notSignedIn }
        guard !rows.isEmpty else { return }
        var query: [URLQueryItem] = []
        if let onConflict { query.append(URLQueryItem(name: "on_conflict", value: onConflict)) }
        let body = try JSONEncoder().encode(rows)
        _ = try await send(method: "POST", path: "rest/v1/\(table)", query: query, body: body, prefer: "return=minimal,resolution=merge-duplicates", authed: true)
    }

    /// The minimum supported iOS build (`MinimumBuild`), read with the publishable key alone. Nil when the row is missing
    /// or malformed; throws on a network or HTTP failure. The caller fails open on both.
    public func minimumBuild() async throws -> MinimumBuild? {
        try await iosAppConfig().minimum
    }

    /// The public `app_config` row 'ios', read once with the publishable key alone: the minimum supported build (nil
    /// when the row is missing or malformed) and the owner's remote switches (`RemoteFlags`, every one on unless the row
    /// turns it off). Throws on a network or HTTP failure; the caller then keeps what it had.
    public func iosAppConfig() async throws -> (minimum: MinimumBuild?, flags: RemoteFlags) {
        let data = try await send(method: "GET", path: "rest/v1/app_config",
                                  query: [URLQueryItem(name: "key", value: "eq.ios"), URLQueryItem(name: "select", value: "value")],
                                  body: nil, prefer: nil, authed: false)
        return (MinimumBuild.parse(data), RemoteFlags.parse(data))
    }

    /// Calls a Postgres function through PostgREST RPC with the current session (or the publishable key).
    public func rpc<T: Decodable>(_ function: String, _ arguments: [String: String] = [:], authed: Bool = false) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: arguments)
        let data = try await send(method: "POST", path: "rest/v1/rpc/\(function)", query: [], body: body, prefer: nil, authed: authed)
        return try decode(data, as: T.self)
    }

    /// `rpc` for a function whose arguments aren't all text — block numbers, a flag, a null (`history_read`'s
    /// `p_from_block`, `p_meta_only`) — as JSON values: a whole number goes as digits, never "1.0", so PostgREST hands a
    /// `bigint` argument its value; and the answer as it came, for the caller to parse (`HistoryServerClient`). The same
    /// request as `rpc`: the publishable key, or the session when `authed`. Throws `SupabaseError.http` with the status and
    /// body for anything but a 2xx, and the transport's error when there is no answer.
    public func rpcJSON(name: String, body: [String: JSON], authed: Bool = false) async throws -> Data {
        let encoded = try JSONEncoder().encode(body)
        return try await send(method: "POST", path: "rest/v1/rpc/\(name)", query: [], body: encoded, prefer: nil, authed: authed)
    }

    /// Deletes rows matching the query. Requires a session.
    public func delete(_ table: String, query: [URLQueryItem]) async throws {
        guard currentSession != nil else { throw SupabaseError.notSignedIn }
        _ = try await send(method: "DELETE", path: "rest/v1/\(table)", query: query, body: nil, prefer: "return=minimal", authed: true)
    }

    // MARK: Storage

    /// Uploads bytes to a public Storage bucket and returns the public URL. Requires a session; RLS on
    /// `storage.objects` decides whether the wallet may write to that path. Only the resulting public URL is stored
    /// in a row — never the bytes. `upsert: false` for a write-once bucket (launch-media, whose URLs go on-chain):
    /// an object that already exists is then refused (`isDuplicateUpload`) instead of overwritten. The object is served
    /// with its bucket's cache lifetime (`cacheControl(forBucket:)`).
    @discardableResult
    public func uploadPublic(bucket: String, path: String, data: Data, contentType: String, upsert: Bool = true) async throws -> URL {
        let request = try storageUpload(bucket: bucket, path: path, contentType: contentType, upsert: upsert)
        let (respData, response) = try await session.upload(for: request, from: data)
        return try uploaded(bucket: bucket, path: path, respData, response)
    }

    /// `uploadPublic`, streaming the body from a file (a picked video) so it is never read into memory whole.
    @discardableResult
    public func uploadPublic(bucket: String, path: String, file: URL, contentType: String, upsert: Bool = true) async throws -> URL {
        let request = try storageUpload(bucket: bucket, path: path, contentType: contentType, upsert: upsert)
        let (respData, response) = try await session.upload(for: request, fromFile: file)
        return try uploaded(bucket: bucket, path: path, respData, response)
    }

    /// The public URL of an object in a public bucket.
    public nonisolated func publicURL(bucket: String, path: String) -> URL {
        baseURL.appending(path: "storage/v1/object/public/\(bucket)/\(path)")
    }

    /// Whether Storage refused an upload sent with `upsert: false` because the object already exists: HTTP 409, or
    /// the older API's 400 whose body carries statusCode "409" / error "Duplicate".
    public static func isDuplicateUpload(_ error: Error) -> Bool {
        guard case .http(let code, let body)? = error as? SupabaseError else { return false }
        if code == 409 { return true }
        guard code == 400, let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return false }
        // not localized: Storage's own English, matched as it sends it
        return (object["statusCode"].map { "\($0)" } == "409") || (object["error"] as? String) == "Duplicate"
    }

    /// The `Cache-Control` an upload to `bucket` is stored with: Storage keeps an upload's header as the object's
    /// `cacheControl` and answers every read of it with that, and keeps `no-cache` when there is none — which made every
    /// read of every object a revalidation (all 59 measured 2026-10-08).
    /// - `launch-media`: a week, as the app keeps its own copy (`ImagePipeline.immutableLifetime`). The bucket is
    ///   write-once (supabase migration 26: no upload over an object, no move or rename) and its URLs go on chain, so the
    ///   bytes behind one never change — but a takedown deletes the object, and a browser, a wallet or a proxy showing it
    ///   outside the app must stop within a week too, which a year's `immutable` would have forbidden for good.
    /// - Any other bucket, `avatars` among them: none (Storage's `no-cache`). `avatars/<wallet>/avatar.jpg` is uploaded
    ///   over, and every read reaching Storage is what makes a new one show at once.
    public static func cacheControl(forBucket bucket: String) -> String? {
        bucket == "launch-media" ? "public, max-age=604800" : nil // not localized: an HTTP header value
    }

    private func storageUpload(bucket: String, path: String, contentType: String, upsert: Bool) throws -> URLRequest {
        guard let token = currentSession?.accessToken else { throw SupabaseError.notSignedIn }
        var request = URLRequest(url: baseURL.appending(path: "storage/v1/object/\(bucket)/\(path)"))
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(upsert ? "true" : "false", forHTTPHeaderField: "x-upsert")
        if let cacheControl = Self.cacheControl(forBucket: bucket) { request.setValue(cacheControl, forHTTPHeaderField: "Cache-Control") }
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private func uploaded(bucket: String, path: String, _ data: Data, _ response: URLResponse) throws -> URL {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SupabaseError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return publicURL(bucket: bucket, path: path)
    }

    /// Deletes every object under `prefix` (a folder) in a Storage bucket: lists first, then removes what is there,
    /// so an empty folder is simply a no-op (Storage answers a blind delete of a missing object with an error).
    /// RLS on `storage.objects` decides whether the wallet owns those paths. Requires a session. Returns the count.
    @discardableResult
    public func deleteObjects(bucket: String, prefix: String) async throws -> Int {
        guard let token = currentSession?.accessToken else { throw SupabaseError.notSignedIn }
        func storageRequest(_ method: String, _ path: String, json: [String: Any]) throws -> URLRequest {
            var request = URLRequest(url: baseURL.appending(path: "storage/v1/\(path)"))
            request.httpMethod = method
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            return request
        }
        let (listData, listResponse) = try await session.data(for: try storageRequest("POST", "object/list/\(bucket)", json: ["prefix": prefix, "limit": 1000]))
        if let http = listResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SupabaseError.http(http.statusCode, String(data: listData, encoding: .utf8) ?? "")
        }
        let entries = (try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]]) ?? []
        // Folders come back without an id; only real objects are deletable.
        let paths = entries.compactMap { entry -> String? in
            guard entry["id"] is String, let name = entry["name"] as? String else { return nil }
            return "\(prefix)/\(name)"
        }
        guard !paths.isEmpty else { return 0 }
        let (deleteData, deleteResponse) = try await session.data(for: try storageRequest("DELETE", "object/\(bucket)", json: ["prefixes": paths]))
        if let http = deleteResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SupabaseError.http(http.statusCode, String(data: deleteData, encoding: .utf8) ?? "")
        }
        return paths.count
    }

    // MARK: Edge Functions

    /// How long the app waits for `pin-media`. The function answers within its own 20 s budget (BUDGET_MS in
    /// supabase/functions/pin-media/index.ts) and sends nothing before it answers, so this bounds the whole call and
    /// leaves room for a cold start and the network (security audit 2026-09-26, RW-9).
    public static let pinMediaTimeout: TimeInterval = 25

    /// Pins an already-uploaded public object to IPFS through the `pin-media` Edge Function (Pinata) and returns its
    /// `ipfs://<cid>` URI, for writing on-chain as a Moment's permanent media pointer. Requires a session; throws if
    /// the function is unavailable, busy (`rateLimited`) or doesn't answer in `pinMediaTimeout` — the caller tells the
    /// user and never writes the https URL on-chain in its place on its own (RI-9).
    public func pinToIPFS(bucket: String, path: String) async throws -> String {
        guard currentSession != nil else { throw SupabaseError.notSignedIn }
        let body = try JSONSerialization.data(withJSONObject: ["bucket": bucket, "path": path])
        let data: Data
        do {
            data = try await send(method: "POST", path: "functions/v1/pin-media", query: [], body: body, prefer: nil, authed: true,
                                  timeout: Self.pinMediaTimeout)
        } catch SupabaseError.http(429, let text) {
            throw SupabaseError.rateLimited(retryAfter: Self.retryAfter(text))
        }
        struct Response: Decodable { let uri: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.uri.hasPrefix("ipfs://") else {
            throw SupabaseError.decoding(L10n.string(LocalizedStringResource("the pin-media response", bundle: L10n.kit, comment: "What the app could not read, completing “Could not read <this> from the server.”")))
        }
        return response.uri
    }

    /// The email-wallet pepper (see `EmailWallet`): posts e and t — hashes, never the email, password or seed — to the
    /// `email-pepper` function, which answers an HMAC of them under a key only the server holds. Called before
    /// sign-in. Each email has two budgets there: an anonymous one (publishable key only), which anyone who knows the
    /// address can spend, and a separate verified one, paid for by a Privy email one-time-code token for that email
    /// (`rememberEmailProof`), sent as the bearer; the client network's limit counts both. Throws
    /// `EmailPepperError.verificationRequired` when the anonymous budget is spent (verify the email, remember its token,
    /// retry), `.verificationExpired` / `.verificationMismatch` when the remembered token is refused (it is forgotten),
    /// and `SupabaseError.rateLimited` (with the wait) when only waiting helps: the network's limit is spent, or both
    /// budgets are. A spent verified budget drops the proof and falls back to the anonymous one (see `afterRateLimit`).
    public func emailPepper(e: Data, t: Data) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["e": String(e.hexString.dropFirst(2)), "t": String(t.hexString.dropFirst(2))])
        let proof = emailProofs[e]
        let data: Data
        do {
            data = try await pepperRequest(body, proof: proof)
        } catch SupabaseError.http(429, let text) {
            data = try await afterRateLimit(text, body: body, e: e, proof: proof)
        } catch SupabaseError.http(401, _) where proof != nil {
            forgetEmailProof(proof, for: e)
            throw EmailPepperError.verificationExpired
        } catch SupabaseError.http(400, let text) where proof != nil && Self.isProofMismatch(text) {
            forgetEmailProof(proof, for: e)
            throw EmailPepperError.verificationMismatch
        }
        struct Response: Decodable { let p: String }
        guard let p = try? JSONDecoder().decode(Response.self, from: data).p, Self.isHex32Bytes(p), let pepper = Data(hex: p) else {
            throw SupabaseError.decoding(L10n.string(LocalizedStringResource("the email pepper", bundle: L10n.kit, comment: "What the app could not read, completing “Could not read <this> from the server.”")))
        }
        return pepper
    }

    /// One `email-pepper` request: with `proof` as the bearer (verified budget), or with no Authorization (anonymous).
    private func pepperRequest(_ body: Data, proof: String?) async throws -> Data {
        try await send(method: "POST", path: "functions/v1/email-pepper", query: [], body: body, prefer: nil, authed: false,
                       authorization: proof.map { .bearer($0) } ?? .none)
    }

    /// `email-pepper` answered 429 (`text`). The client network's limit (`"limit": "network"`) counts every request,
    /// proven or not, so it only means wait. Otherwise the request's own budget for e is spent. Without a proof, the
    /// verified budget may still have room: ask for the one-time code. With one, the anonymous budget may: the proof is
    /// dropped and the request made once more without it, and if that is refused too, wait for whichever budget frees
    /// first — never a loop back to "verify", which could not help.
    private func afterRateLimit(_ text: String, body: Data, e: Data, proof: String?) async throws -> Data {
        let wait = Self.retryAfter(text)
        if Self.isNetworkLimit(text) { throw SupabaseError.rateLimited(retryAfter: wait) }
        guard let proof else { throw EmailPepperError.verificationRequired(retryAfter: wait) }
        forgetEmailProof(proof, for: e)
        do {
            return try await pepperRequest(body, proof: nil)
        } catch SupabaseError.http(429, let text) {
            let anonymousWait = Self.retryAfter(text)
            if Self.isNetworkLimit(text) { throw SupabaseError.rateLimited(retryAfter: anonymousWait) }
            throw SupabaseError.rateLimited(retryAfter: [wait, anonymousWait].compactMap { $0 }.min())
        }
    }

    /// A 429 from `email-pepper` caused by the client network's limit, which no email proof changes.
    private static func isNetworkLimit(_ text: String) -> Bool { serverField(text, "limit") as? String == "network" }

    /// Remember the Privy access token a fresh email one-time code produced for `email`: `emailPepper` then pays for
    /// that email's peppers from its verified budget. It is never sent anywhere else.
    public func rememberEmailProof(_ privyAccessToken: String, forEmail email: String) {
        emailProofs[EmailWallet.emailHash(email)] = privyAccessToken
    }

    /// Drop every remembered email proof (the flow that obtained them is over).
    public func forgetEmailProofs() { emailProofs = [:] }

    /// Drop a refused proof — unless a newer one replaced it while the request was in flight.
    private func forgetEmailProof(_ proof: String?, for e: Data) {
        if emailProofs[e] == proof { emailProofs[e] = nil }
    }

    /// `email-pepper`'s 400s for a proof that doesn't cover the e it was sent with.
    private static func isProofMismatch(_ text: String) -> Bool {
        let reason = serverField(text, "error") as? String
        // not localized: email-pepper's own English, matched as it sends it
        return reason == "the verified email does not match" || reason == "no verified email on this Privy account"
    }

    /// Calls an Edge Function that authenticates the caller with its own bearer token (not a Supabase session) —
    /// e.g. `delete-account`, which takes the Privy access token. Returns the response body.
    public func invoke(function: String, bearer: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "functions/v1/\(function)"))
        request.httpMethod = "POST"
        request.httpBody = body ?? Data("{}".utf8)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SupabaseError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: Transport

    /// What a request carries in `Authorization`: the session token when `authed`, else the publishable key (the
    /// default); a caller's own bearer token; or nothing (the publishable key still goes in `apikey`).
    private enum AuthorizationHeader { case standard, bearer(String), none }

    private func send(method: String, path: String, query: [URLQueryItem], body: Data?, prefer: String?, authed: Bool,
                      authorization: AuthorizationHeader = .standard, timeout: TimeInterval = 25) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        switch authorization {
        case .standard:
            let bearer = (authed ? currentSession?.accessToken : nil) ?? anonKey
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .none:
            break
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SupabaseError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// A Postgres `timestamptz` as PostgREST prints it ("2026-09-20T10:00:00.123456+00:00": fractional seconds of any
    /// length, or none), to the second; nil for anything else.
    public static func timestamp(_ text: String) -> Date? {
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: whole)
    }

    /// Exactly 64 lowercase hex characters (32 bytes), as the server's nonces and peppers are.
    private static func isHex32Bytes(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// One top-level field of a JSON error body, if the body is a JSON object.
    private static func serverField(_ text: String, _ key: String) -> Any? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?[key]
    }

    /// The `retryAfter` seconds a 429 body carries, rounded up and clamped to a day — it comes off the network, and
    /// `Int(Double)` traps on anything non-finite or out of range.
    static func retryAfter(_ text: String) -> Int? {
        guard let seconds = (serverField(text, "retryAfter") as? NSNumber)?.doubleValue, seconds.isFinite else { return nil }
        return Int(min(max(0, seconds.rounded(.up)), 86_400))
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: data) }
        catch { throw SupabaseError.decoding(String(describing: T.self)) }
    }
}
