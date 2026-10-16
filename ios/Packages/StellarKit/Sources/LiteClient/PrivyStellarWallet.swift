import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StellarCore

// Stellar for the accounts that sign in with Privy: Apple, Google, an email code or a Privy passkey (DyorHQ/internal
// ios-app/stellar-v2/privy-stellar-wallets.md). Privy holds their keys, so their Stellar key is a Privy wallet the user
// owns. The phone makes it and signs with it itself, through Privy's client API (https://auth.privy.io, as Privy's own
// SDKs call it, with the user's access token): DyorHQ's servers are never in that path. The phone still builds and
// checks everything it signs; for each hash the user's own Privy key (in the Privy SDK, on this iPhone) authorizes the
// exact raw_sign request, and the signature is used only once it verifies for the account's address. A wallet is used
// only once Privy says only the user controls it (`PrivyWalletCheck`).

/// The account's Stellar wallet at Privy, as this iPhone keeps it once checked.
public struct PrivyStellarWallet: Codable, Equatable, Sendable {
    /// Privy's id of the wallet, named in every raw_sign request.
    public let walletId: String
    /// The account's Stellar address (G…).
    public let address: String

    public init(walletId: String, address: String) {
        self.walletId = walletId
        self.address = address
    }
}

/// A wallet as Privy's client API describes it: whose it is, and who else may sign with it.
public struct PrivyWalletRecord: Decodable, Equatable, Sendable {
    public struct Signer: Decodable, Equatable, Sendable {
        public let signerId: String

        public init(signerId: String) { self.signerId = signerId }

        enum CodingKeys: String, CodingKey { case signerId = "signer_id" }
    }

    public let id: String
    public let address: String
    public let chainType: String
    /// The key quorum that owns the wallet: for a user's wallet, the user's own.
    public let ownerId: String?
    /// Key quorums that may sign besides the owner.
    public let additionalSigners: [Signer]
    /// When the wallet's key was imported (ms): whoever imported it knows it.
    public let importedAt: Int64?
    public let archivedAt: Int64?
    public let createdAt: Int64?

    public var wallet: PrivyStellarWallet { PrivyStellarWallet(walletId: id, address: address) }

    enum CodingKeys: String, CodingKey {
        case id, address
        case chainType = "chain_type"
        case ownerId = "owner_id"
        case additionalSigners = "additional_signers"
        case importedAt = "imported_at"
        case archivedAt = "archived_at"
        case createdAt = "created_at"
    }

    public init(id: String, address: String, chainType: String, ownerId: String?, additionalSigners: [Signer] = [],
                importedAt: Int64? = nil, archivedAt: Int64? = nil, createdAt: Int64? = nil) {
        self.id = id
        self.address = address
        self.chainType = chainType
        self.ownerId = ownerId
        self.additionalSigners = additionalSigners
        self.importedAt = importedAt
        self.archivedAt = archivedAt
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        address = try c.decode(String.self, forKey: .address)
        chainType = try c.decode(String.self, forKey: .chainType)
        ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId)
        // A record that doesn't say who else signs counts as one with signers (`PrivyWalletCheck.trusted` refuses it).
        additionalSigners = try c.decodeIfPresent([Signer].self, forKey: .additionalSigners)
            ?? [Signer(signerId: "(not given)")]
        importedAt = try c.decodeIfPresent(Int64.self, forKey: .importedAt)
        archivedAt = try c.decodeIfPresent(Int64.self, forKey: .archivedAt)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt)
    }
}

/// The raw_sign request the phone authorizes for one hash: Privy's authorization payload is `{version, method, url,
/// body, headers}`, with exactly these values, and the same body and headers are sent. The host's `authorize` turns it
/// into the Privy SDK's `WalletApiPayload` (`version`, `url`, `method`, `headers`, `body`).
public struct PrivyRawSignRequest: Equatable, Sendable {
    public static let version = 1
    /// How long Privy may take to act on it: two minutes.
    public static let lifetime: TimeInterval = 120

    public let walletId: String
    /// 0x and 64 lowercase hex: the hash this iPhone computed.
    public let hash: String
    /// Milliseconds since 1970: the request's `privy-request-expiry`.
    public let expiresAt: Int64
    /// DyorHQ's Privy app id (public).
    public let appId: String

    public init(walletId: String, hash: [UInt8], appId: String, now: Date) {
        self.walletId = walletId
        self.hash = "0x" + hash.map { String(format: "%02x", $0) }.joined()
        expiresAt = Int64(((now.timeIntervalSince1970 + Self.lifetime) * 1000).rounded(.down))
        self.appId = appId
    }

    public var method: String { "POST" }
    /// Privy's client route, as its SDKs sign it.
    public var url: String { PrivyWalletAPI.base.appendingPathComponent("api/v1/wallets/\(walletId)/raw_sign").absoluteString }
    /// The Privy headers sent, and so signed: the app and the expiry.
    public var headers: [String: String] { ["privy-app-id": appId, "privy-request-expiry": String(expiresAt)] }
    /// The body, `{"params": {"hash": …}}`.
    public var body: Body { Body(params: .init(hash: hash)) }

    public struct Body: Codable, Equatable, Sendable {
        public struct Params: Codable, Equatable, Sendable { public let hash: String }
        public let params: Params
    }
}

/// What the phone needs of Privy's wallets. `PrivyWalletAPI` is Privy; tests pass fakes.
public protocol PrivyWalletBackend: Sendable {
    /// The wallet Privy has under `id`, as the signed-in user may read it.
    func wallet(id: String) async throws -> PrivyWalletRecord
    /// A new Stellar wallet owned by the signed-in user.
    func createStellarWallet() async throws -> PrivyWalletRecord
    /// The signed-in user's Stellar wallets as Privy lists them to the user's own session; nil where Privy doesn't list
    /// them there, and the caller reads Privy's identity token instead.
    func stellarWallets() async throws -> [PrivyWalletRecord]?
    /// Privy's signature (64 bytes) of `request.hash`, for `authorization`: the user's authorization signature of
    /// exactly `request`.
    func rawSign(_ request: PrivyRawSignRequest, authorization: String) async throws -> [UInt8]
}

/// Privy refused or couldn't answer. `status` 401 means the user's Privy session needs a sign-in again.
public enum PrivyAPIError: Error, Equatable {
    case transport(String)
    case refused(status: Int, code: String?)
    case unavailable(status: Int)
    case decoding(String)
}

/// Privy's client API, called as Privy's own SDKs call it: the signed-in user's access token, DyorHQ's app and client
/// ids, and this app's bundle id. No DyorHQ server and no app secret are involved.
public struct PrivyWalletAPI: PrivyWalletBackend {
    public static let base = URL(string: "https://auth.privy.io")!

    private let appId: String
    private let clientId: String
    private let nativeAppIdentifier: String
    private let accessToken: @Sendable () async throws -> String
    private let session: URLSession

    /// - Parameters:
    ///   - clientId: the app client's id (the iOS client), as the Privy SDK is configured with it.
    ///   - nativeAppIdentifier: this app's bundle id, which Privy matches against the client's.
    ///   - accessToken: the signed-in user's Privy access token, fresh (the Privy SDK's `getAccessToken`).
    public init(appId: String, clientId: String, nativeAppIdentifier: String,
                accessToken: @escaping @Sendable () async throws -> String, session: URLSession = .shared) {
        self.appId = appId
        self.clientId = clientId
        self.nativeAppIdentifier = nativeAppIdentifier
        self.accessToken = accessToken
        self.session = session
    }

    public func wallet(id: String) async throws -> PrivyWalletRecord {
        guard Self.isWalletId(id) else { throw PrivyAPIError.decoding("a wallet id") }
        return try JSONDecoder().decode(PrivyWalletRecord.self, from: try await send("GET", "api/v1/wallets/\(id)"))
    }

    public func createStellarWallet() async throws -> PrivyWalletRecord {
        let body = try JSONEncoder().encode(["chain_type": "stellar"])
        return try JSONDecoder().decode(PrivyWalletRecord.self, from: try await send("POST", "api/v1/wallets", body: body))
    }

    public func stellarWallets() async throws -> [PrivyWalletRecord]? {
        struct Page: Decodable { let data: [PrivyWalletRecord] }
        do {
            return try JSONDecoder().decode(Page.self, from: try await send("GET", "api/v1/wallets", query: [URLQueryItem(name: "chain_type", value: "stellar")])).data
        } catch PrivyAPIError.refused(let status, _) where [401, 403, 404, 405].contains(status) {
            // Privy doesn't open this route to every app's user sessions (it answered 401 on testnet, to a token the
            // wallet reads take): no list, and the identity token says instead. Any other refusal is an error.
            return nil
        }
    }

    public func rawSign(_ request: PrivyRawSignRequest, authorization: String) async throws -> [UInt8] {
        guard Self.isWalletId(request.walletId) else { throw PrivyAPIError.decoding("a wallet id") }
        let data = try await send("POST", "api/v1/wallets/\(request.walletId)/raw_sign", body: try JSONEncoder().encode(request.body),
                                  extra: request.headers.merging(["privy-authorization-signature": authorization]) { $1 })
        struct Answer: Decodable {
            struct Inner: Decodable { let signature: String }
            let data: Inner?
            let signature: String?
        }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        guard let hex = answer.data?.signature ?? answer.signature, let bytes = Self.hexBytes(hex), bytes.count == 64 else {
            throw PrivyAPIError.decoding("the signature")
        }
        return bytes
    }

    /// Privy's wallet ids: letters, digits, `_` and `-`, never a path.
    static func isWalletId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      extra: [String: String] = [:]) async throws -> Data {
        var url = Self.base.appendingPathComponent(path)
        if !query.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query
            url = parts.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.httpBody = body
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        for (name, value) in ["privy-app-id": appId, "privy-client-id": clientId, "x-native-app-identifier": nativeAppIdentifier,
                              "Content-Type": "application/json", "Accept": "application/json"].merging(extra, uniquingKeysWith: { $1 }) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw PrivyAPIError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 429 || status >= 500 { throw PrivyAPIError.unavailable(status: status) }
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
            throw PrivyAPIError.refused(status: status, code: code)
        }
        return data
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        let digits = Array(hex.hasPrefix("0x") ? hex.dropFirst(2) : Substring(hex))
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[i...i + 1]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }
}

/// A Privy account's Stellar key: Privy holds it, and the user's own Privy key authorizes each signature on this iPhone.
/// It signs only the hash it is given (a transaction this iPhone checked, or a SEP-53 digest), and its answer verifies
/// for `address` or isn't used.
public struct PrivyStellarSigner: StellarHashSigner {
    public let address: String
    public let walletId: String
    private let appId: String
    private let backend: any PrivyWalletBackend
    private let authorize: @Sendable (PrivyRawSignRequest) async throws -> String
    private let recheck: PrivyWalletRecheck?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - authorize: the user's Privy authorization signature of the request (the Privy SDK's
    ///     `generateAuthorizationSignature`), made on this iPhone.
    ///   - recheck: run before the first signature (`PrivyWalletRecheck`): the wallet, read from this iPhone's storage,
    ///     must still be only the user's at Privy.
    public init(wallet: PrivyStellarWallet, appId: String, backend: any PrivyWalletBackend,
                authorize: @escaping @Sendable (PrivyRawSignRequest) async throws -> String,
                recheck: PrivyWalletRecheck? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        address = wallet.address
        walletId = wallet.walletId
        self.appId = appId
        self.backend = backend
        self.authorize = authorize
        self.recheck = recheck
        self.now = now
    }

    public func signHash(_ hash: [UInt8]) async throws -> [UInt8] {
        // The request's URL names the wallet: a malformed id is never signed for.
        guard hash.count == 32, PrivyWalletAPI.isWalletId(walletId) else { throw StellarSigningError.badSignature }
        try await recheck?.ensure()
        let request = PrivyRawSignRequest(walletId: walletId, hash: hash, appId: appId, now: now())
        let authorization = try await authorize(request)
        let signature = try await backend.rawSign(request, authorization: authorization)
        guard StellarSigner.verify(address: address, message: hash, signature: signature) else { throw StellarSigningError.badSignature }
        return signature
    }
}

/// A check that runs until it first passes, then never again (for one signer's life, so once per Stellar session):
/// callers at the same time share one run, and a failure is not kept, so the next signature tries again.
public final class PrivyWalletRecheck: Sendable {
    private actor State {
        var passed = false
        var running: Task<Void, Error>?

        func ensure(_ check: @escaping @Sendable () async throws -> Void) async throws {
            if passed { return }
            if let running { return try await running.value }
            let task = Task { try await check() }
            running = task
            defer { running = nil }
            try await task.value
            passed = true
        }
    }

    private let state = State()
    private let check: @Sendable () async throws -> Void

    public init(_ check: @escaping @Sendable () async throws -> Void) { self.check = check }

    public func ensure() async throws { try await state.ensure(check) }
}

/// Which Privy wallet a Privy account's Stellar key is (privy-stellar-wallets.md §5.3). Only one only the user controls:
/// owned by the user's own key quorum, the one that owns the account's Privy Monad wallet (Privy made that one at the
/// account's sign-up); no other signer; not imported, since whoever imported a key knows it. Privy says all of it to
/// this iPhone directly: anyone else able to make wallets for the user (DyorHQ's app secret, in the wrong hands) can't
/// make one this iPhone uses.
public enum PrivyWalletCheck {
    public enum Failure: Error, Equatable {
        /// The account's Privy Monad wallet has no owner to compare with, or Privy answered with another wallet.
        case noOwner
        /// The wallet kept for the account, or the one just made, isn't one only the user controls.
        case notOnlyTheUsers
        /// The list the wallet is looked for in can't be relied on: an identity token Privy couldn't refresh, with no
        /// wallet found in it, or one listing a Stellar wallet with no id to read (none is chosen then: the one it hides
        /// may be the oldest). Nothing is made, so an account never gets a second Stellar wallet for want of a whole,
        /// current list.
        case listNotFresh
        /// Privy lists no wallets to the user's session and issued no identity token: the Privy app doesn't send them
        /// (its "Return user data in an identity token" setting), so this sign-in can't find its wallet, now or later.
        case noIdentityToken
    }

    /// A Stellar wallet as Privy's identity token lists it; Privy may leave the id out.
    public struct Listed: Equatable, Sendable {
        public let id: String?
        public let address: String
    }

    /// Whether `record` is a Stellar wallet only the user controls, `owner` being the user's own key quorum. One the user
    /// exported stays theirs: Privy exports a key only with its owner's authorization, so only the user can have it.
    public static func trusted(_ record: PrivyWalletRecord, owner: String) -> Bool {
        record.chainType == "stellar" && StrKey.isValid(.accountID, record.address) && PrivyWalletAPI.isWalletId(record.id)
            && record.ownerId == owner && record.additionalSigners.isEmpty && record.importedAt == nil && record.archivedAt == nil
    }

    /// The account's Stellar wallet, with no prompt:
    /// - the one this iPhone kept (`kept`), if it kept one, and only if it is still only the user's;
    /// - else the oldest of the user's Stellar wallets that is only the user's: as Privy lists them to the user's session,
    ///   or, where it doesn't, as Privy's identity token lists them;
    /// - else a new one, made now by Privy for the user, and checked as the others are.
    /// `ownerWalletId` is the account's Privy Monad wallet (an embedded Ethereum wallet at `ownerAddress`), whose owner is
    /// the user's own key quorum. A wallet the token lists that Privy won't show this user (404, 403) is passed over; an
    /// outage throws; and a wallet is made only from a list known to be complete and current (Privy's own, or an identity
    /// token just refreshed, `identityTokenIsFresh`, whose every Stellar wallet could be read), so a second wallet is
    /// never made for want of an answer.
    public static func resolve(backend: any PrivyWalletBackend, ownerWalletId: String, ownerAddress: String, kept: PrivyStellarWallet?,
                               identityToken: String?, identityTokenIsFresh: Bool = true) async throws -> PrivyStellarWallet {
        let owner = try await owner(backend: backend, ownerWalletId: ownerWalletId, ownerAddress: ownerAddress)
        if let kept {
            try await confirm(kept, backend: backend, owner: owner)
            return kept
        }
        let found: [PrivyWalletRecord]
        let current: Bool
        if let listed = try await backend.stellarWallets() {
            found = listed.filter { trusted($0, owner: owner) }
            current = true
        } else {
            if identityToken == nil, identityTokenIsFresh { throw Failure.noIdentityToken }
            let read = try await fromIdentityToken(identityToken, backend: backend, owner: owner)
            guard read.complete else { throw Failure.listNotFresh }
            found = read.found
            current = identityToken != nil && identityTokenIsFresh
        }
        if let oldest = found.min(by: { ($0.createdAt ?? .max) < ($1.createdAt ?? .max) }) { return oldest.wallet }
        guard current else { throw Failure.listNotFresh }
        let made = try await backend.createStellarWallet()
        guard trusted(made, owner: owner) else { throw Failure.notOnlyTheUsers }
        return made.wallet
    }

    /// That the wallet this iPhone kept for the account is still only the user's at Privy (its owner the key quorum that
    /// owns the account's Privy Monad wallet, no other signer, not imported or archived), as each Stellar session checks
    /// before its first signature: what this iPhone stored is never trusted on its own.
    public static func confirm(_ kept: PrivyStellarWallet, backend: any PrivyWalletBackend, ownerWalletId: String,
                               ownerAddress: String) async throws {
        try await confirm(kept, backend: backend, owner: owner(backend: backend, ownerWalletId: ownerWalletId, ownerAddress: ownerAddress))
    }

    /// The user's own key quorum: the owner of the account's Privy Monad wallet, read from Privy, which must answer with
    /// that wallet (its id, an Ethereum wallet, at the account's address).
    private static func owner(backend: any PrivyWalletBackend, ownerWalletId: String, ownerAddress: String) async throws -> String {
        let monad = try await backend.wallet(id: ownerWalletId)
        guard monad.id == ownerWalletId, monad.chainType == "ethereum", monad.address.lowercased() == ownerAddress.lowercased(),
              let owner = monad.ownerId, !owner.isEmpty else { throw Failure.noOwner }
        return owner
    }

    private static func confirm(_ kept: PrivyStellarWallet, backend: any PrivyWalletBackend, owner: String) async throws {
        let record = try await backend.wallet(id: kept.walletId)
        guard trusted(record, owner: owner), record.wallet == kept else { throw Failure.notOnlyTheUsers }
    }

    /// The trusted Stellar wallets among those Privy's identity token lists, each read from Privy, and whether every one
    /// it lists could be read (one with no id can't: the list is then not whole enough to choose from).
    private static func fromIdentityToken(_ identityToken: String?, backend: any PrivyWalletBackend,
                                          owner: String) async throws -> (found: [PrivyWalletRecord], complete: Bool) {
        var found: [PrivyWalletRecord] = []
        var complete = true
        for listed in stellarWallets(inIdentityToken: identityToken ?? "") {
            guard let id = listed.id, PrivyWalletAPI.isWalletId(id) else {
                complete = false
                continue
            }
            let record: PrivyWalletRecord
            do {
                record = try await backend.wallet(id: id)
            } catch PrivyAPIError.refused(let status, _) where status == 403 || status == 404 {
                continue
            }
            if trusted(record, owner: owner), record.address == listed.address { found.append(record) }
        }
        return (found, complete)
    }

    /// Whether the identity token read after a refresh (`refreshed`; `before`, the one held as it began) is current, so a
    /// wallet may be made from what it lists: the refresh went through, and Privy issued a new token (each issue is a
    /// new string, signed anew); or, where it didn't reissue it, the token is from a sign-in under a minute before the
    /// refresh began (`began`), by its `iat` against this iPhone's clock, so a clock running fast only ever fails that
    /// second case. No token at all counts as current: `resolve` then says Privy issues none.
    public static func isCurrent(_ refreshed: String?, before: String?, refreshWentThrough: Bool, began: Date) -> Bool {
        guard refreshWentThrough else { return false }
        guard let refreshed else { return true }
        if refreshed != before { return true }
        return (issuedAt(identityToken: refreshed) ?? .distantPast) >= began.addingTimeInterval(-60)
    }

    /// Whether the wallet a lookup found (`found`) may be kept as the account's: it is the one this iPhone already kept,
    /// or none is kept, and the Stellar address this iPhone has for the account, if any, is its. Kept once, never swapped.
    public static func mayKeep(_ found: PrivyStellarWallet, kept: PrivyStellarWallet?, stellarAddress: String?) -> Bool {
        (kept == nil || kept == found) && (stellarAddress == nil || stellarAddress == found.address)
    }

    /// When Privy issued `token` (its `iat` claim); nil when it can't be read.
    public static func issuedAt(identityToken token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = base64url(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let iat = claims["iat"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: iat.doubleValue)
    }

    /// The Stellar wallets a Privy identity token's `linked_accounts` claim lists (a JSON string, or an array); none when
    /// the token can't be read or lists none. The token is the Privy SDK's, fetched from Privy.
    public static func stellarWallets(inIdentityToken token: String) -> [Listed] {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = base64url(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return [] }
        var linked = claims["linked_accounts"] as? [[String: Any]]
        if linked == nil, let text = claims["linked_accounts"] as? String, let data = text.data(using: .utf8) {
            linked = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        }
        return (linked ?? []).compactMap { account in
            guard account["chain_type"] as? String == "stellar", let address = account["address"] as? String else { return nil }
            return Listed(id: account["id"] as? String, address: address)
        }
    }

    private static func base64url(_ text: String) -> Data? {
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
}
