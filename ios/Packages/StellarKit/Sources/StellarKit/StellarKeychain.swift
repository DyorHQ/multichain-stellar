import Foundation
@_exported import LiteClient
@_exported import StellarCore

#if canImport(Security)
import Security

/// Where Lite keeps what it needs between launches, per account and network:
/// - the Stellar seed for accounts whose secret isn't re-derivable at signing time (email & password, imported key):
///   Keychain, `WhenUnlockedThisDeviceOnly`, never synced, never backed up;
/// - the Lite session: its access token and the refresh token that renews it (not keys: a session only reads and
///   builds; every transaction still needs the seed). Same attributes as the seed.
/// Passkey (Mera) and phrase accounts never store a Stellar seed: it is derived from the phrase inside the signing
/// session and dropped with it.
public enum StellarKeychain {
    static let service = "fun.dyorhq.lite"

    public static func saveSeed(_ seed: [UInt8], account: String, network: String) throws {
        try save(Data(seed), key: "seed.\(network).\(account)")
    }

    public static func seed(account: String, network: String) -> [UInt8]? {
        load(key: "seed.\(network).\(account)").map { [UInt8]($0) }
    }

    /// The session, replacing the stored one whole: its access token, and the refresh token that renews it (single use,
    /// so each refresh saves its successor here). The item is this device's only, like the seed; its format is
    /// `LiteSavedSession`'s.
    public static func saveSession(token: String, expiresAt: Date, refreshToken: String? = nil, refreshExpiresAt: Date? = nil, account: String, network: String) throws {
        let saved = LiteSavedSession(token: token, expiresAt: expiresAt, refreshToken: refreshToken, refreshExpiresAt: refreshExpiresAt)
        try save(try saved.data(), key: "session.\(network).\(account)")
    }

    /// The access token. A session saved without a refresh token (or before there were any) loads the same.
    public static func session(account: String, network: String) -> (token: String, expiresAt: Date)? {
        savedSession(account: account, network: network).map { ($0.token, $0.expiresAt) }
    }

    /// The refresh token saved with the session, and when it lapses (nil when its answer didn't say); nil when the
    /// session has none.
    public static func refreshToken(account: String, network: String) -> (token: String, expiresAt: Date?)? {
        guard let saved = savedSession(account: account, network: network), let token = saved.refreshToken else { return nil }
        return (token, saved.refreshExpiresAt)
    }

    /// The session alone, refresh token included (signing out of Stellar on this iPhone): the stored seed stays, so the
    /// account signs in again without its secret being entered again.
    public static func eraseSession(account: String, network: String) {
        delete(key: "session.\(network).\(account)")
    }

    private static func savedSession(account: String, network: String) -> LiteSavedSession? {
        load(key: "session.\(network).\(account)").flatMap(LiteSavedSession.init(data:))
    }

    /// Everything Lite stored for `account`, sessions and their refresh tokens included (sign-out, account deletion,
    /// "erase this device").
    public static func erase(account: String) {
        for network in ["testnet", "mainnet"] {
            delete(key: "seed.\(network).\(account)")
            delete(key: "session.\(network).\(account)")
        }
    }

    // ---------------------------------------------------------------------------------------------- Keychain

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    private static func save(_ data: Data, key: String) throws {
        delete(key: key)
        var q = base(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static func load(key: String) -> Data? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func delete(key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }
}
#endif
