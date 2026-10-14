import DyorKit
import Foundation
import Security

/// Stores an imported wallet's raw private key in this device's Keychain and nowhere else: not synced to iCloud
/// (`ThisDeviceOnly`), never written to a server, never logged. The address is re-derived from the key on load, so
/// a tampered entry simply fails to load rather than signing for the wrong account.
enum ImportedWalletStore {
    private static let service = "fun.dyorhq.imported"
    private static let account = "primary"

    /// Whether the key is now in the Keychain. A failed write must not be treated as saved: the key would sign for this
    /// session only and be gone after the next launch.
    @discardableResult
    static func save(privateKey: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let previous = loadKey()
        SecItemDelete(query as CFDictionary)
        func add(_ key: Data) -> OSStatus {
            var add = query
            add[kSecValueData as String] = key
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false // explicit: never sync the key to iCloud Keychain
            return SecItemAdd(add as CFDictionary, nil)
        }
        guard add(privateKey) == errSecSuccess else {
            // Put back the wallet this replaced (and keep its tag), so a failed import never loses the current key.
            if let previous { _ = add(previous) }
            return false
        }
        LocalWalletMeta.clear() // default: a plain imported key; a password sign-in re-tags it right after saving
        return true
    }

    static func loadAccount() -> Secp256k1Account? {
        guard let key = loadKey() else { return nil }
        return Secp256k1Account(privateKey: key)
    }

    static var exists: Bool { loadKey() != nil }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        LocalWalletMeta.clear()
    }

    private static func loadKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }
}

/// Tags how the device-local key in `ImportedWalletStore` was created, so the session restores it with the right
/// method and label after a relaunch. An imported key has no tag (`.imported`); an email + password key records the
/// email so the account reads "Email & Password (you@example.com)" rather than "Imported wallet".
enum LocalWalletMeta {
    enum Kind: String { case emailPassword }
    private static let kindKey = "localWallet.kind.v1"
    private static let emailKey = "localWallet.email.v1"

    struct Meta { let kind: Kind; let email: String? }

    static func setEmailPassword(email: String) {
        UserDefaults.standard.set(Kind.emailPassword.rawValue, forKey: kindKey)
        UserDefaults.standard.set(email, forKey: emailKey)
    }

    static func load() -> Meta? {
        guard let raw = UserDefaults.standard.string(forKey: kindKey), let kind = Kind(rawValue: raw) else { return nil }
        return Meta(kind: kind, email: UserDefaults.standard.string(forKey: emailKey))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: kindKey)
        UserDefaults.standard.removeObject(forKey: emailKey)
    }
}
