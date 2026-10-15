// What the Stellar screens last showed, kept on the device (docs/DESIGN-stellar-parity.md §3.9). Internal builds only
// (STELLAR_LITE).
#if STELLAR_LITE
import CryptoKit
import DyorKit
import Foundation
import StellarKit

/// The Stellar section's saved figures: DyorKit's `SavedScreens`, as Monad's money screens keep theirs, in a folder of its
/// own per network and deployment (`saved-screens-stellar-<network>-<deployment8>` in Application Support), keyed by the
/// account's Monad address. After a redeploy, what the old contracts showed is never shown again; Monad's folder never
/// holds a Stellar figure.
///
/// - Screens: `.home` (the Earn total with it), `.portfolio`, `.launchBoard`, `.momentsBoard`, `.myLaunchpad`. Earn
///   positions themselves are never saved, as on Monad.
/// - A screen notes `epoch(for:)` when its read begins and saves only once it read everything, with that epoch: a save
///   for an account forgotten since (`forget`), or after this device's figures were erased, is dropped.
/// - `forget` removes the account's files: sign-out and erase of the device (`DyorHQLiteKeys.forget`), and Sign out of
///   Stellar (`LiteSession.onSignOut`).
final class StellarSaved: @unchecked Sendable {
    /// The screens it keeps.
    static let screens: [SavedScreens.Screen] = [.home, .portfolio, .launchBoard, .momentsBoard, .myLaunchpad]

    /// The build's: the pinned network and deployment, in Application Support, for this version of the app.
    static let shared = StellarSaved(screens: SavedScreens(directory: folder(pinned: LiteGate.pinned), build: appBuild))

    /// A save's guard, taken when the read that brings it begins.
    struct Epoch: Equatable, Sendable {
        let saved: Int
        let forgets: Int
    }

    let screens: SavedScreens
    private let lock = NSLock()
    /// How many times each account was forgotten: a read that began before is saved for none.
    private var forgets: [Address: Int] = [:]

    init(screens: SavedScreens) {
        self.screens = screens
    }

    /// `saved-screens-stellar-<network>-<deployment8>` in Application Support; nil (nothing saved or shown) without one.
    static func folder(pinned: PinnedContracts) -> URL? {
        let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support?.appending(path: folderName(pinned: pinned))
    }

    static func folderName(pinned: PinnedContracts) -> String {
        "saved-screens-stellar-\(pinned.network.name)-\(deployment(pinned))"
    }

    /// The first 8 hex digits of the sha256 of the pinned launchpad and Moments contracts: a new deployment gets a new
    /// folder.
    static func deployment(_ pinned: PinnedContracts) -> String {
        let ids = (pinned.contracts("launchpad") + ["|"] + pinned.contracts("moments")).joined(separator: ",")
        return CryptoKit.SHA256.hash(data: Data(ids.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The app's version and build, as Monad's saved screens name it: a file another build wrote is never shown.
    static var appBuild: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "")-\(info?["CFBundleVersion"] as? String ?? "")"
    }

    /// What a read for `owner` notes as it begins.
    func epoch(for owner: Address) -> Epoch {
        lock.withLock { Epoch(saved: screens.epoch, forgets: forgets[owner, default: 0]) }
    }

    /// `screen` as last saved for `owner`, when it may be shown (`SavedScreens.load`).
    func load<T: Decodable>(_ type: T.Type, _ screen: SavedScreens.Screen, owner: Address) -> SavedScreens.Saved<T>? {
        screens.load(type, screen, wallet: owner)
    }

    /// Saves `value` as `screen` for `owner`, read at `savedAt`, unless the account was forgotten or the figures erased
    /// since `epoch`.
    func save<T: Encodable & Sendable>(_ value: T, _ screen: SavedScreens.Screen, owner: Address, savedAt: Date, epoch: Epoch) {
        guard lock.withLock({ forgets[owner, default: 0] == epoch.forgets }) else { return }
        screens.save(value, screen, wallet: owner, savedAt: savedAt, epoch: epoch.saved)
    }

    /// Removes every screen saved for `owner`; no read that began before this saves anything for it.
    func forget(_ owner: Address) {
        lock.withLock { forgets[owner, default: 0] += 1 }
        for screen in Self.screens { screens.remove(screen, wallet: owner) }
    }
}
#endif
