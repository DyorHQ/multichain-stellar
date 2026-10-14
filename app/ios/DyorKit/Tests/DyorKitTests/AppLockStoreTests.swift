import XCTest
@testable import DyorKit

/// App Lock across an erase of this device's data (`AppLockStore`). The re-review's finding, from before build 17: the
/// erase removed App Lock's saved setting with everything else, and signing back in without a relaunch wrote `session.`,
/// `mera.`, `localWallet.` and `settings.` keys, so the next launch took the device for an install from before App
/// Lock's default and started it OFF (security audit 2026-09-26, IOSK-4).
final class AppLockStoreTests: XCTestCase {
    /// A store in memory, as `UserDefaults` keeps one domain.
    private final class Store: AppLockDefaults {
        var values: [String: Any] = [:]
        func removePersistentDomain(forName domainName: String) { values = [:] }
        func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    }

    func testAnEraseSavesAppLockAsANewInstallHasIt() {
        for canAuthenticateOwner in [true, false] {
            let store = Store()
            store.values = [AppLockStore.key: !canAuthenticateOwner, "venueTokens.v1": Data([1]), "session.account": "0x7777777777777777777777777777777777777777"]
            XCTAssertEqual(AppLockStore.erase(store, domain: "fun.dyorhq.app", canAuthenticateOwner: canAuthenticateOwner), canAuthenticateOwner)
            XCTAssertEqual(store.values.keys.sorted(), [AppLockStore.key], "everything else erased")
            XCTAssertEqual(store.values[AppLockStore.key] as? Bool, canAuthenticateOwner,
                           "ON where the device can verify its owner, OFF where it can't, whatever was saved before")
            // A sign-in in the same process writes keys that tell an earlier install apart: App Lock stays saved, so the
            // next launch reads it rather than deciding it.
            store.values["session.watchOnly"] = true
            store.values["mera.sessionLength"] = 900
            XCTAssertEqual(store.values[AppLockStore.key] as? Bool, canAuthenticateOwner)
        }
    }

    /// The app erases this device's data through `AppLockStore` only, with the fresh-install rule, and sets the setting in
    /// memory to match; the setting it saves is the one `AppSettings` reads at launch.
    func testTheAppErasesThroughIt() throws {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        let app = ios.appendingPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        func source(_ path: String) throws -> String {
            try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let session = try source("Wallet/Session.swift")
        let erase = try XCTUnwrap(session.range(of: "func eraseLocalData() async {")).upperBound
        let body = session[erase...]
        let saved = try XCTUnwrap(body.range(of: "let appLock = AppLockStore.erase(UserDefaults.standard, domain: bundle, canAuthenticateOwner: BiometricGate.canAuthenticateOwner)"))
        let inMemory = try XCTUnwrap(body.range(of: "settings?.requireBiometrics = appLock"))
        XCTAssertLessThan(saved.upperBound, inMemory.lowerBound)
        XCTAssertLessThan(inMemory.upperBound, try XCTUnwrap(body.range(of: "state = .signedOut")).lowerBound, "before the sign-out")
        XCTAssertTrue(try source("App/AppEnvironment.swift").contains("session.settings = settings"))

        // Nothing else in the app erases the store.
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("removePersistentDomain"), file.lastPathComponent)
        }

        // `AppSettings` reads and saves App Lock under the same key, and a change of it isn't reported to the backend
        // mirror (`onChange` marks the settings changed, which would keep the next sign-in's restore out).
        let theme = try source("Design/Theme.swift")
        XCTAssertTrue(theme.contains("var requireBiometrics: Bool { didSet { defaults.set(requireBiometrics, forKey: \"\(AppLockStore.key)\") } }"))
        XCTAssertTrue(theme.contains("requireBiometrics = defaults.object(forKey: \"\(AppLockStore.key)\") as? Bool ?? Self.appLockDefault(defaults)"))
        XCTAssertTrue(theme.contains("let on = !isEarlierInstall && BiometricGate.canAuthenticateOwner"), "the fresh-install rule the erase uses")
    }
}
