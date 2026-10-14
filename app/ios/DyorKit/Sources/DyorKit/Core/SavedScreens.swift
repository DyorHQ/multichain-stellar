import Foundation

/// What each money screen last showed for a wallet — Home, the Portfolio, the Launch and Moments boards and My Launchpad —
/// kept on the device, so a screen opened paints it at once, before its own reads answer (speed work, 2026-10-09). Every
/// one of those screens otherwise opened empty, and Home waited 5–10 s for its slowest read.
///
/// A saved screen is a starting point, never a fresh read: the screen says when it was read ("Updated 3 min ago") for as
/// long as any of it shows, reads everything again at once, and replaces it part by part as each read lands. A part whose
/// read then fails keeps its saved figures, still said to be saved, beside the error and its Retry.
///
/// - One file per screen and wallet (`fileName`), in Application Support and out of backups. The file names its screen,
///   its wallet, the build of the app that wrote it and when it was read, and is shown only when all of them match what
///   is asked for (`load`): never another wallet's, never one an older build wrote (whose rules for a coin's text, or
///   whose shape, may differ), and never one older than `maxAge` or dated ahead of the clock by more than `maxSkew`
///   (`isShowable`): a day-old balance is no longer a starting point.
/// - Saved off the main thread, one file after another in the order asked (`save`). An erase of this device's data
///   removes every file (`erase`), and a save asked for by a read that began before it is dropped (`epoch`), so nothing
///   of an erased account comes back. One screen's file is removed the same way when what it holds can no longer be
///   vouched for (`remove`: the Portfolio's figures, once the history they were built from is dropped). A screen too big
///   to save (`maxBytes`) isn't saved, and its older file is removed, so the screen never opens on something older than
///   its last read.
/// - With no directory (a local fork, whose chain a restart replaces), nothing is saved or shown.
///
/// Only what the chain and the app's own reads answered is saved, the same values the screen showed; the file is the app's
/// own sandbox, trusted as the registry's (`DyorCoinStore`) is. A picture's link in it still goes through
/// `ImageSourcePolicy`, and a Moment's media through its keccak check, like any other.
public final class SavedScreens: @unchecked Sendable {
    /// A screen whose last state is kept.
    public enum Screen: String, CaseIterable, Sendable {
        case home
        case portfolio
        case launchBoard = "launch-board"
        case momentsBoard = "moments-board"
        case myLaunchpad = "my-launchpad"
    }

    /// A screen as it was saved: what it showed, and when that was read.
    public struct Saved<Value> {
        public let value: Value
        /// When what it holds was read: the oldest of its parts', when they were read at different times.
        public let savedAt: Date

        public init(value: Value, savedAt: Date) {
            self.value = value
            self.savedAt = savedAt
        }
    }

    /// The oldest saved screen shown: a day.
    public static let maxAge: TimeInterval = 24 * 60 * 60
    /// How far ahead of the device's clock a save may be dated and still be shown (a clock set back a little): never
    /// "Updated in 3 hr".
    public static let maxSkew: TimeInterval = 5 * 60
    /// The largest file saved: a screen of creators' long texts (a launch's description can be 44 KB) isn't kept, and is
    /// read as before.
    public static let maxBytes = 2 * 1024 * 1024
    /// The files' format; a file of another is never shown.
    static let format = 1

    /// Where the files are; nil saves and shows nothing.
    public let directory: URL?
    /// The app's build: a file another build wrote is never shown.
    private let build: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var currentEpoch = 0
    /// Counts each file's removals (`remove`), by file name: a save asked for before one never lands after it.
    private var removals: [String: Int] = [:]
    /// Saves run here, one after another, in the order asked: a newer save is never overwritten by an older one.
    private let queue = DispatchQueue(label: "fun.dyorhq.saved-screens", qos: .utility)

    /// `build` names the app's build (its version and build number); `now` is the device clock, which dates and ages saves.
    public init(directory: URL?, build: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.build = build
        self.now = now
    }

    /// `saved-screens-<chain>` in the app's Application Support folder, or nothing saved when there is none.
    public static func applicationSupport(build: String, chainId: Int = Monad.chainId) -> SavedScreens {
        let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return SavedScreens(directory: folder?.appending(path: "saved-screens-\(chainId)"), build: build)
    }

    /// Counts the erases: a screen notes it when its read begins, and what it read is saved only if none happened since.
    public var epoch: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentEpoch
    }

    /// Whether something read at `savedAt` may be shown at `now`: less than `maxAge` old, and dated no more than `maxSkew`
    /// ahead of the clock. A screen whose parts were read at different times asks it of each part.
    public static func isShowable(savedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= -maxSkew && age < maxAge
    }

    /// `screen` as last saved for `wallet` (nil: no wallet signed in), when it may be shown (`isShowable`), was written by
    /// this build, for this screen and this wallet; nil otherwise, or when it can't be read as `T`. A save dated ahead of
    /// the clock is dated now: what it holds is never said to be newer than it can be.
    public func load<T: Decodable>(_ type: T.Type, _ screen: Screen, wallet: Address?) -> Saved<T>? {
        lock.lock()
        defer { lock.unlock() }
        guard let directory, let data = try? Data(contentsOf: directory.appending(path: Self.fileName(screen, wallet: wallet))),
              let file = try? JSONDecoder().decode(SavedScreenFile<T>.self, from: data),
              file.format == Self.format, file.build == build, file.screen == screen.rawValue, file.wallet == Self.walletKey(wallet) else { return nil }
        let savedAt = Date(timeIntervalSince1970: file.savedAt)
        let now = now()
        guard Self.isShowable(savedAt: savedAt, now: now) else { return nil }
        return Saved(value: file.value, savedAt: min(savedAt, now))
    }

    /// Saves `value` as `screen` for `wallet`, read at `savedAt`, off the main thread, after any save asked for before it;
    /// dropped when this device's data was erased since `epoch` (what `epoch` said when the read that brought it began).
    /// A value too big to save (`maxBytes`) removes the screen's file instead.
    public func save<T: Encodable & Sendable>(_ value: T, _ screen: Screen, wallet: Address?, savedAt: Date, epoch: Int) {
        guard directory != nil else { return }
        let removal = removals(of: Self.fileName(screen, wallet: wallet))
        queue.async { [self] in
            write(value, screen, wallet: wallet, savedAt: savedAt, epoch: epoch, removal: removal)
        }
    }

    /// Removes `screen`'s file for `wallet`, what it holds no longer vouched for — the Portfolio's figures once the history
    /// they were built from is dropped (`HistoryModel.restart`): not shown from now on, and no save asked for before this
    /// lands after it, as for an erase. A save asked for after it is written as any other.
    public func remove(_ screen: Screen, wallet: Address?) {
        let name = Self.fileName(screen, wallet: wallet)
        lock.lock()
        defer { lock.unlock() }
        removals[name, default: 0] += 1
        if let directory { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
    }

    private func removals(of name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return removals[name, default: 0]
    }

    /// Removes every saved screen of every wallet (an erase of this device's data): none is shown from now on, and no save
    /// asked for by a read that began before this lands after it.
    public func erase() {
        lock.lock()
        defer { lock.unlock() }
        currentEpoch += 1
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits for every save asked for so far to be written (tests).
    func waitForSaves() {
        queue.sync {}
    }

    /// Holds every save not yet written until `semaphore` is signalled (tests): a save asked for now is written after
    /// whatever the test does meanwhile.
    func holdSaves(until semaphore: DispatchSemaphore) {
        queue.async { semaphore.wait() }
    }

    /// `<screen>-<wallet>.json`, the wallet in lower case, "signed-out" for none.
    static func fileName(_ screen: Screen, wallet: Address?) -> String {
        "\(screen.rawValue)-\(walletKey(wallet)).json"
    }

    private static func walletKey(_ wallet: Address?) -> String {
        wallet.map { $0.hex.lowercased() } ?? "signed-out"
    }

    /// One atomic write, out of backups, under the lock: an erase or a removal waits for it, then removes it. Encoded before
    /// the lock is taken, so a large screen never holds up a screen reading `epoch` or `load` meanwhile. Dropped when the
    /// device's data was erased since `epoch`, or the file removed since `removal` (its count of removals when asked).
    private func write<T: Encodable>(_ value: T, _ screen: Screen, wallet: Address?, savedAt: Date, epoch: Int, removal: Int) {
        guard let directory else { return }
        let file = SavedScreenFile(format: Self.format, build: build, screen: screen.rawValue, wallet: Self.walletKey(wallet),
                                   savedAt: savedAt.timeIntervalSince1970, value: value)
        let data = try? JSONEncoder().encode(file)
        let name = Self.fileName(screen, wallet: wallet)
        lock.lock()
        defer { lock.unlock() }
        guard epoch == currentEpoch, removals[name, default: 0] == removal else { return }
        var url = directory.appending(path: name)
        guard let data, data.count <= Self.maxBytes else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// What a board with nothing on it shows while it waits for its first read (the Launch and Moments boards): until a read
/// has answered in this session — what the board holds, or why it couldn't be read — or the board saved when it was last
/// read is shown (`SavedScreens`), nothing says what it holds, so the spinner shows, never "No Launches Yet" or "No
/// Moments yet". That includes the frames before the first read's task starts, when nothing is reading yet. A read that
/// failed says so, with Retry, rather than spin, until one is under way again.
public enum BoardFirstRead {
    /// Whether a board shows its spinner: it has nothing to show (`empty`), and either no read has answered (`answered`)
    /// or one is under way (`reading`).
    public static func isLoading(empty: Bool, answered: Bool, reading: Bool) -> Bool {
        empty && (reading || !answered)
    }
}

/// A saved screen on disk (`SavedScreens`): what wrote it, for whom, when it was read, and what the screen showed.
struct SavedScreenFile<Value> {
    let format: Int
    let build: String
    let screen: String
    let wallet: String
    /// Unix seconds.
    let savedAt: Double
    let value: Value
}

extension SavedScreenFile: Encodable where Value: Encodable {}
extension SavedScreenFile: Decodable where Value: Decodable {}
