import Foundation

/// App Lock's saved setting (`settings.biometrics`, the app's `AppSettings.requireBiometrics`) across an erase of this
/// device's data, here so it is tested (R14).
public enum AppLockStore {
    /// The UserDefaults key App Lock is saved under.
    public static let key = "settings.biometrics"

    /// Erases `defaults`' `domain` (Delete Account, Forget This Device), then saves App Lock as a new install has it: ON
    /// where the device can verify its owner, OFF where it can't (App Lock fails closed there, and would block every
    /// signature). A launch decides App Lock only where nothing is saved, and takes a store holding what an earlier run
    /// writes (`session.`, `mera.`, `localWallet.`, `settings.`…) for an install from before App Lock's default, which
    /// stays OFF (security audit 2026-09-26, IOSK-4). The next sign-in in this process writes those keys, so without this
    /// save the next launch would start App Lock OFF. Returns what was saved, for the setting in memory.
    @discardableResult
    public static func erase(_ defaults: some AppLockDefaults, domain: String, canAuthenticateOwner: Bool) -> Bool {
        defaults.removePersistentDomain(forName: domain)
        defaults.set(canAuthenticateOwner, forKey: key)
        return canAuthenticateOwner
    }
}

/// What `AppLockStore.erase` needs of the store: `UserDefaults`, or a test's in memory.
public protocol AppLockDefaults {
    func removePersistentDomain(forName domainName: String)
    func set(_ value: Bool, forKey defaultName: String)
}

extension UserDefaults: AppLockDefaults {}
