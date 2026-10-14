import CryptoKit
import Foundation

/* Perpl's authenticated API uses an Ed25519 key the user enrolls once with a wallet EIP-712 signature; after that
   every REST request and the trading-WS sign-in is signed with that key. The private key is generated on device
   and never leaves it (the server only stores the public key). This is the pure crypto + the enrollment HTTP
   calls; the app supplies the wallet's EIP-712 signature via Privy. See docs.perpl.xyz/.../api/authentication. */

/// A stored Perpl API key: the opaque server token plus the 32-byte Ed25519 secret, both kept in the Keychain.
public struct PerplApiKey: Sendable, Codable, Equatable {
    public let token: String
    public let secret: Data
    public let address: String
    public let scopeMask: Int

    public init(token: String, secret: Data, address: String, scopeMask: Int) {
        self.token = token
        self.secret = secret
        self.address = address
        self.scopeMask = scopeMask
    }
}

extension PerplApiKey: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted on purpose: the Ed25519 secret and bearer token must never appear in a log, `print`, interpolation,
    /// or crash reflection.
    public var description: String { "PerplApiKey(address: \(address), secret: <redacted>, token: <redacted>)" }
    public var debugDescription: String { description }
}

public enum PerplScope {
    public static let read = 1
    public static let trade = 2
    public static let all = 3
}

public enum PerplAuth {
    // MARK: Encodings

    /// base64url with no padding, as every Perpl signature/nonce uses.
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func sha256hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The 6-field REST canonical string.
    public static func restCanonical(chainId: Int, method: String, target: String, timestamp: String, nonce: String, body: String) -> String {
        [String(chainId), method, target, timestamp, nonce, sha256hex(Data(body.utf8))].joined(separator: "\n")
    }

    /// The 4-field trading-WS sign-in canonical string.
    public static func wsSigninCanonical(chainId: Int, timestamp: String, nonce: String) -> String {
        [String(chainId), "trading-ws-signin", timestamp, nonce].joined(separator: "\n")
    }

    // MARK: Ed25519

    public static func newSecret() -> Data { Curve25519.Signing.PrivateKey().rawRepresentation }

    public static func publicKeyHex(secret: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        return "0x" + key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// Ed25519 signature over the raw bytes, base64url — for REST/WS canonical strings.
    public static func sign(_ message: Data, secret: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        return base64url(try key.signature(for: message))
    }

    /// The Ed25519 proof-of-possession over the 32-byte EIP-712 digest, `0x`-hex — sent as `pop_signature`.
    public static func proofOfPossession(digest: Data, secret: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        return "0x" + (try key.signature(for: digest)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Runs the two-step enrollment and signs REST requests. The wallet EIP-712 signature is supplied by the caller
/// (the app asks Privy to `secp256k1Sign` the same digest), so this stays free of any wallet dependency.
public actor PerplAuthClient {
    public struct Payload: Sendable {
        /// The server's typed data, echoed back unchanged to `/enroll` (its `mac` covers it). Validated, never signed as is.
        public let typedData: [String: Any]
        public let mac: String
        /// The 32-byte EIP-712 digest the wallet must sign and the Ed25519 PoP must cover — recomputed on device from
        /// the validated typed data (`PerplEnrollment.validate`), never taken from the server.
        public let digest: Data
        /// The wallet and Ed25519 public key the typed data was validated against.
        public let address: String
        public let publicKeyHex: String
    }

    private let chainId: Int
    private let apiBase: URL
    private let session: URLSession

    public init(chainId: Int = 143, apiBase: URL = PerplService.restBase, session: URLSession = .shared) {
        self.chainId = chainId
        self.apiBase = apiBase
        self.session = session
    }

    /// Step 1: ask the server for the typed data to sign, validate it strictly against this request (this wallet, this
    /// key, these terms — see `PerplEnrollment`), and compute its digest locally. Throws before anything can be signed.
    public func requestPayload(address: String, publicKeyHex: String, scopeMask: Int, label: String, now: Date = Date()) async throws -> Payload {
        let body: [String: Any] = ["chain_id": chainId, "address": address, "public_key": publicKeyHex, "scope_mask": scopeMask, "label": label]
        let json = try await post("v1/api-key/payload", body: body)
        guard let typedData = json["typed_data"] as? [String: Any], let mac = json["mac"] as? String, !mac.isEmpty else {
            throw PerplError.malformedResponse(L10n.string(LocalizedStringResource("api-key payload", bundle: L10n.kit, comment: "What Perpl sent that the app could not read, completing “Perpl sent <this> the app could not read.”")))
        }
        let validated = try PerplEnrollment.validate(typedData, chainId: chainId, address: address, publicKeyHex: publicKeyHex,
                                                     scopeMask: scopeMask, label: label, now: now)
        // The documented response carries no digest, and one is never used. If the server sends one anyway and it
        // names a different message than the typed data, it is asking for a blind signature: refuse outright.
        for field in ["digest", "hash"] where json[field] != nil {
            guard let claimed = json[field] as? String, Data(hex: claimed) == validated.digest else { throw PerplEnrollmentError.digestMismatch }
        }
        return Payload(typedData: typedData, mac: mac, digest: validated.digest, address: address, publicKeyHex: publicKeyHex)
    }

    /// Step 2: submit both signatures and receive the API-key token.
    public func enroll(address: String, secret: Data, payload: Payload, walletSignature: String, scopeMask: Int) async throws -> PerplApiKey {
        // The payload was validated for one wallet and one key; never prove possession for another over it.
        guard Address(address) != nil, Address(address) == Address(payload.address) else { throw PerplEnrollmentError.foreignSigner }
        guard try PerplAuth.publicKeyHex(secret: secret).lowercased() == payload.publicKeyHex.lowercased() else { throw PerplEnrollmentError.foreignKey }
        let pop = try PerplAuth.proofOfPossession(digest: payload.digest, secret: secret)
        let body: [String: Any] = [
            "chain_id": chainId, "address": address, "typed_data": payload.typedData, "mac": payload.mac,
            "signature": walletSignature, "pop_signature": pop,
        ]
        let json: [String: Any]
        do { json = try await post("v1/api-key/enroll", body: body) }
        catch PerplError.contextUnavailable(status: 409) { throw PerplEnrollRefusal.keyAlreadyRegistered }
        catch PerplError.contextUnavailable(status: 423) { throw PerplEnrollRefusal.keyLimitReached }
        guard let info = json["api_key"] as? [String: Any], let token = info["api_key"] as? String else {
            throw PerplError.malformedResponse(L10n.string(LocalizedStringResource("api-key enroll", bundle: L10n.kit, comment: "What Perpl sent that the app could not read, completing “Perpl sent <this> the app could not read.”")))
        }
        return PerplApiKey(token: token, secret: secret, address: address, scopeMask: scopeMask)
    }

    /// A signed GET against a history endpoint (fills, order-history, …). `target` is the path+query exactly as the
    /// gateway receives it — leading slash, no `/api` prefix, e.g. `/v1/trading/fills?count=100` — signed byte for
    /// byte and appended verbatim to the API base, so the query survives (URL.appending(path:) would percent-encode
    /// the `?` and break it). Matches PerplFoundation/api-docs examples/js/authed_rest_requests.js.
    public func signedGet(_ target: String, key: PerplApiKey, timestamp: String, nonce: String) async throws -> Data {
        let canonical = PerplAuth.restCanonical(chainId: chainId, method: "GET", target: target, timestamp: timestamp, nonce: nonce, body: "")
        let signature = try PerplAuth.sign(Data(canonical.utf8), secret: key.secret)
        guard let url = URL(string: apiBase.absoluteString + target) else { throw PerplError.malformedResponse(L10n.string(LocalizedStringResource("history URL", bundle: L10n.kit, comment: "What Perpl sent that the app could not read, completing “Perpl sent <this> the app could not read.”"))) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(key.token, forHTTPHeaderField: "X-API-Key")
        request.setValue(timestamp, forHTTPHeaderField: "X-API-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-API-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-API-Signature")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw PerplError.contextUnavailable(status: http.statusCode) }
        return data
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: apiBase.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        // Native apps send no Origin, which Perpl's enrollment endpoints accept (whitelisted-or-absent).
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 25
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PerplError.contextUnavailable(status: http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PerplError.malformedResponse(L10n.string(LocalizedStringResource("json object", bundle: L10n.kit, comment: "What Perpl sent that the app could not read, completing “Perpl sent <this> the app could not read.”"))) }
        return json
    }
}

/// Perpl refused to register a trading key (`POST v1/api-key/enroll`), in words a person can act on.
public enum PerplEnrollRefusal: Error, LocalizedError, Equatable {
    /// 409: this public key is registered already, or was revoked (a revoked key never comes back). A new key is needed.
    case keyAlreadyRegistered
    /// 423: the Perpl account has the most active API keys it allows (16).
    case keyLimitReached

    public var errorDescription: String? {
        switch self {
        case .keyAlreadyRegistered: return L10n.tr("Perpl already has this trading key. Nothing was changed; try connecting again.")
        case .keyLimitReached: return L10n.tr("Your Perpl account has the most API keys it allows (16). Remove keys you no longer use under API Keys on app.perpl.xyz, then try again.")
        }
    }
}
