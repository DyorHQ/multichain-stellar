import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StellarCore

// Stellar for the accounts that sign in with Privy: Apple, Google, an email code or a Privy passkey (DyorHQ/internal
// ios-app/stellar-v2/privy-stellar-wallets.md §5.2). Privy holds their keys, so their Stellar key is a Privy wallet the
// user owns. The phone still builds and checks everything it signs; for each hash it asks the user's own Privy key (in
// the Privy SDK, on this iPhone) to authorize the exact raw_sign request, the Lite API adds DyorHQ's app secret and
// relays it, and the signature is used only once it verifies for the account's address.

/// POST /v1/privy/wallet's answer: the account's Stellar wallet at Privy.
public struct PrivyWallet: Codable, Equatable, Sendable {
    /// Privy's id of the wallet, named in every raw_sign request.
    public let walletId: String
    /// The account's Stellar address (G…).
    public let address: String

    public init(walletId: String, address: String) {
        self.walletId = walletId
        self.address = address
    }
}

/// POST /v1/privy/sign's answer.
struct PrivySignature: Codable, Equatable, Sendable {
    /// 0x and 128 hex.
    let signature: String
}

/// The raw_sign request the phone authorizes for one hash: Privy's authorization payload is `{version, method, url,
/// body, headers}`, with exactly these values, and the Lite API forwards the same body and headers. The host's
/// `authorize` turns it into the Privy SDK's `WalletApiPayload` (`version`, `url`, `method`, `headers`, `body`).
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
    public var url: String { "https://api.privy.io/v1/wallets/\(walletId)/raw_sign" }
    /// The Privy headers sent, and so signed: the app and the expiry.
    public var headers: [String: String] { ["privy-app-id": appId, "privy-request-expiry": String(expiresAt)] }
    /// The body, `{"params": {"hash": …}}`.
    public var body: Body { Body(params: .init(hash: hash)) }

    public struct Body: Codable, Equatable, Sendable {
        public struct Params: Codable, Equatable, Sendable { public let hash: String }
        public let params: Params
    }
}

/// What the Privy signer needs of the Lite API: the relay of one authorized request. `LiteAPI` is one; tests pass fakes.
public protocol PrivySigningBackend: Sendable {
    /// Privy's signature (64 bytes) of `request.hash`, for `authorization`: the user's authorization signature of
    /// exactly `request`.
    func privySign(_ request: PrivyRawSignRequest, authorization: String) async throws -> [UInt8]
}

extension LiteAPI: PrivySigningBackend {
    /// The account's Stellar wallet for a Privy token the user holds (the identity token): made the first time, kept
    /// after. Public: it runs before the account has a session.
    public func privyWallet(privyToken: String, timeout: TimeInterval = 30) async throws -> PrivyWallet {
        try await request("POST", "privy/wallet", body: ["privyToken": privyToken], access: .public, timeout: timeout)
    }

    public func privySign(_ request: PrivyRawSignRequest, authorization: String) async throws -> [UInt8] {
        struct Body: Encodable { let walletId: String; let hash: String; let expiresAt: Int64; let authorization: String }
        let body = Body(walletId: request.walletId, hash: request.hash, expiresAt: request.expiresAt, authorization: authorization)
        let answer: PrivySignature = try await self.request("POST", "privy/sign", body: body, access: .public, timeout: 30)
        guard let bytes = Self.hexBytes(answer.signature), bytes.count == 64 else { throw LiteAPIError.decoding("the signature") }
        return bytes
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
/// for `address` or isn't used: whatever the relay does, it can't make this iPhone attach another signature.
public struct PrivyStellarSigner: StellarHashSigner {
    public let address: String
    public let walletId: String
    private let appId: String
    private let backend: any PrivySigningBackend
    private let authorize: @Sendable (PrivyRawSignRequest) async throws -> String
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - authorize: the user's Privy authorization signature of the request (the Privy SDK's
    ///     `generateAuthorizationSignature`), made on this iPhone.
    public init(address: String, walletId: String, appId: String, backend: any PrivySigningBackend,
                authorize: @escaping @Sendable (PrivyRawSignRequest) async throws -> String,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.address = address
        self.walletId = walletId
        self.appId = appId
        self.backend = backend
        self.authorize = authorize
        self.now = now
    }

    public func signHash(_ hash: [UInt8]) async throws -> [UInt8] {
        guard hash.count == 32 else { throw StellarSigningError.badSignature }
        let request = PrivyRawSignRequest(walletId: walletId, hash: hash, appId: appId, now: now())
        let authorization = try await authorize(request)
        let signature = try await backend.privySign(request, authorization: authorization)
        guard StellarSigner.verify(address: address, message: hash, signature: signature) else { throw StellarSigningError.badSignature }
        return signature
    }
}

/// Whether the wallet the Lite API named for a Privy account may be used (privy-stellar-wallets.md §5.3): a Lite API that
/// answered with an address of its own must not get the account's deposits nor stand in for its signatures.
public enum PrivyWalletCheck {
    /// A Stellar wallet as Privy's identity token lists it; Privy may leave the id out.
    public struct Listed: Equatable, Sendable {
        public let id: String?
        public let address: String
    }

    /// `wallet` may be used when it is the one this iPhone kept for the account (`kept`), if it kept one, and one of the
    /// Stellar wallets Privy's identity token lists, when it lists any. The token is the Privy SDK's, fetched from Privy
    /// after the wallet was made: Privy signed it, and DyorHQ's server never handled it on its way here.
    public static func accepts(_ wallet: PrivyWallet, kept: PrivyWallet?, identityToken: String?) -> Bool {
        if let kept, kept != wallet { return false }
        let listed = identityToken.map(stellarWallets(inIdentityToken:)) ?? []
        return listed.isEmpty || listed.contains { $0.address == wallet.address && ($0.id == nil || $0.id == wallet.walletId) }
    }

    /// The Stellar wallets a Privy identity token's `linked_accounts` claim lists (a JSON string, or an array); none when
    /// the token can't be read or lists none.
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
