import Foundation
@_exported import LiteClient
@_exported import StellarCore

#if canImport(Security)
import Security

/// Where Lite keeps what it needs between launches, per account and network:
/// - the Stellar seed for accounts whose secret isn't re-derivable at signing time (email & password, imported key):
///   Keychain, `WhenUnlockedThisDeviceOnly`, never synced, never backed up;
/// - the Lite session token (not a key: it only reads and builds; every transaction still needs the seed).
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

    public static func saveSession(token: String, expiresAt: Date, account: String, network: String) throws {
        let payload = try JSONEncoder().encode(["token": token, "expiresAt": ISO8601DateFormatter().string(from: expiresAt)])
        try save(payload, key: "session.\(network).\(account)")
    }

    public static func session(account: String, network: String) -> (token: String, expiresAt: Date)? {
        guard let data = load(key: "session.\(network).\(account)"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let token = dict["token"], let exp = dict["expiresAt"].flatMap(ISO8601DateFormatter().date(from:)) else { return nil }
        return (token, exp)
    }

    /// Everything Lite stored for `account` (sign-out, account deletion, "erase this device").
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
