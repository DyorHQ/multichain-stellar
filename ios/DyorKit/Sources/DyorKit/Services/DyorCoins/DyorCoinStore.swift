import Foundation

/// Where `DyorCoinRegistry` keeps what it has read: a JSON file in Application Support (`dyor-coins-143.json`), excluded
/// from backup. It holds public chain facts only — every DyorHQ coin found, and how far each factory's list has been
/// read — nothing about the wallet, so it is shared by every account on the device, and a build that doesn't know the file
/// ignores it. It is not UserDefaults on purpose: a key there with an earlier-install prefix turns App Lock off on a new
/// install (`AppSettings`), and a growing list doesn't belong in preferences. Account deletion removes it (`erase`).
public struct DyorCoinStore: Sendable {
    /// What the file holds.
    public struct Snapshot: Codable, Hashable, Sendable {
        /// The file format; a file of another version is ignored and read again from the chain.
        public static let currentVersion = 1

        public var version: Int
        /// Every coin found, sorted by address so the same set always writes the same bytes.
        public var coins: [DyorCoin]
        /// How many of each factory's launches or Moments have been read, in the order the factory lists them.
        public var checkpoints: [Checkpoint]

        public init(coins: [DyorCoin], checkpoints: [Checkpoint]) {
            version = Self.currentVersion
            self.coins = coins.sorted { $0.address.hex < $1.address.hex }
            self.checkpoints = checkpoints.sorted { $0.factory.hex < $1.factory.hex }
        }

        private enum CodingKeys: String, CodingKey { case version, coins, checkpoints }

        /// The file's contents entry by entry: an entry this build can't read (a launchpad generation a later build added,
        /// a damaged value) is left out, and every other one kept. A coin left out takes its factory's checkpoint with it,
        /// so that list is read again from the start and the coin comes back at the next refresh; when not even its
        /// factory can be read, every checkpoint goes (every list is read again: a few requests).
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            let entries = try container.decode([CoinEntry].self, forKey: .coins)
            coins = entries.compactMap(\.coin)
            let kept = try container.decode([Entry<Checkpoint>].self, forKey: .checkpoints).compactMap(\.value)
            let unread = entries.filter { $0.coin == nil }
            if unread.contains(where: { $0.factory == nil }) {
                checkpoints = []
            } else {
                let factories = Set(unread.compactMap(\.factory))
                checkpoints = kept.filter { !factories.contains($0.factory) }
            }
        }
    }

    /// One entry of a list in the file, nil when it can't be read.
    private struct Entry<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// One coin entry of the file: the coin, or, when it can't be read, the factory it was recorded under, if that
    /// can be read on its own.
    private struct CoinEntry: Decodable {
        let coin: DyorCoin?
        let factory: Address?

        private enum Keys: String, CodingKey { case origin }
        private struct Origin: Decodable { let factory: Address }

        init(from decoder: Decoder) throws {
            coin = try? DyorCoin(from: decoder)
            factory = coin?.factory ?? (try? decoder.container(keyedBy: Keys.self).decode(Origin.self, forKey: .origin).factory)
        }
    }

    /// A launchpad's first `count` launches, or a cohort's Moments 1…`count`, have been read.
    public struct Checkpoint: Codable, Hashable, Sendable {
        public let factory: Address
        public let count: Int

        public init(factory: Address, count: Int) {
            self.factory = factory
            self.count = count
        }
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    /// `dyor-coins-<chain>.json`; a Debug build pointed at a local fork uses its own file (`-fork`), so a fork's coins
    /// and counts never reach the mainnet one, which shares the chain id.
    public static func fileName(chainId: Int = Monad.chainId, fork: Bool = false) -> String {
        "dyor-coins-\(chainId)\(fork ? "-fork" : "").json"
    }

    /// The store in the app's Application Support folder (created when missing); nil when there is none.
    public static func applicationSupport(chainId: Int = Monad.chainId, fork: Bool = false) -> DyorCoinStore? {
        guard let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return DyorCoinStore(url: folder.appending(path: fileName(chainId: chainId, fork: fork)))
    }

    /// What the file holds; nil when there is no file, or it can't be read as a whole or is of another version. An entry
    /// that can't be read is left out (`Snapshot.init(from:)`).
    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == Snapshot.currentVersion else { return nil }
        return snapshot
    }

    /// Replaces the file with `snapshot` in one atomic write, and keeps it out of backups.
    public func save(_ snapshot: Snapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
    }

    /// Deletes the file (account deletion). Nothing to do when there is none.
    public func erase() {
        try? FileManager.default.removeItem(at: url)
    }
}
