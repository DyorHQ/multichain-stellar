import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Counts the erasures of the image caches (`ImagePipeline.removeAll`). It is read and moved on from any thread under a
/// lock, so an erase takes effect at once, with no suspension: a load under way when the account is deleted captured
/// the count before it, and nothing it finishes afterwards is kept — not in memory, not on disk.
public final class ImageCacheEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    public init() {}

    public var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Starts a new epoch: whatever was captured before it is refused from now on.
    public func advance() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// The thumbnails the image pipeline accepted, kept in the app's Caches folder between launches so a picture seen once
/// paints from the phone, with no network, on the next launch. Each file is one thumbnail at one size bucket
/// (`ImageSizeBucket`), named by the SHA-256 of its key (`ImagePipeline.key`: the picture's ordered sources, each with
/// the hash its bytes must match) and the bucket — content-addressed, so another picture can never fill its entry, and
/// the file name says nothing of where it came from. Only bytes the pipeline already accepted are stored: fetched under
/// the caps, keccak-checked where the source asks for it, decoded and re-encoded at the bucket's size (`encode`).
///
/// Bounded: past `capacity` bytes, the files used least recently are deleted until a tenth is free. When a file was
/// stored is its creation date (`storedAt`, which says whether it must be asked about again, `ImagePipeline.lifetime`);
/// when it was last used is its modification date, written at most every `touchInterval` so a scroll doesn't write the
/// disk for every row. An erase (`discardFiles`) takes the whole folder away at once.
public actor ImageDiskCache {
    /// About 200 MB: at the sizes the app shows, several thousand logos and a few hundred Moment cards.
    public static let defaultCapacity = 200 * 1024 * 1024
    /// The largest thumbnail kept: anything bigger isn't worth the room (a 1200 px picture is a few hundred KB).
    public static let maxEntryBytes = 8 * 1024 * 1024
    /// How often a file's last use is written back to the disk.
    public static let touchInterval: TimeInterval = 600

    /// The app's folder for it, under Caches (not backed up, and iOS may empty it when the phone runs out of room).
    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("remote-images-v1", isDirectory: true)
    }

    /// One stored thumbnail.
    public struct Entry: Sendable {
        public let data: Data
        public let bucket: Int
        public let storedAt: Date
    }

    private struct Record {
        var bytes: Int
        var storedAt: Date
        var usedAt: Date
        var touchedAt: Date
    }

    public nonisolated let directory: URL?
    public let capacity: Int
    private let epoch: ImageCacheEpoch
    private let now: @Sendable () -> Date
    /// What the folder holds, read from it on first use; nil until then, and again after an erase.
    private var index: [String: Record]?
    private var indexEpoch = 0
    private var total = 0
    /// When each picture (by its key's digest) was last removed because its sources said it is gone: a write of a
    /// thumbnail fetched before then is refused, so a background write that was slow to land can't bring it back.
    private var removedAt: [String: Date] = [:]

    /// `directory`: where the files go; nil keeps nothing (every lookup misses). `epoch`: the pipeline's erase count,
    /// checked before every write.
    public init(directory: URL?, capacity: Int = defaultCapacity, epoch: ImageCacheEpoch, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.capacity = capacity
        self.epoch = epoch
        self.now = now
    }

    // MARK: Names

    /// The file name of `key` at `bucket`: `<sha256 of the key, hex>-<bucket>`.
    public static func fileName(key: String, bucket: Int) -> String { "\(digest(key))-\(bucket)" }

    private static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func parse(_ name: String) -> (digest: Substring, bucket: Int)? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let digest = name[..<dash]
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), let bucket = Int(name[name.index(after: dash)...]),
              ImageSizeBucket.all.contains(bucket) else { return nil }
        return (digest, bucket)
    }

    // MARK: Reading

    /// The thumbnail of `key` at exactly `bucket`, or nil.
    public func entry(key: String, bucket: Int) -> Entry? {
        read(Self.fileName(key: key, bucket: bucket), bucket: bucket)
    }

    /// The thumbnail of `key` at the smallest bucket from `bucket` up — `bucket` itself first — or nil: a larger one
    /// decodes down to any smaller size with no network.
    public func entry(key: String, atLeast bucket: Int) -> Entry? {
        let digest = Self.digest(key)
        for size in ImageSizeBucket.all where size >= bucket {
            if let found = read("\(digest)-\(size)", bucket: size) { return found }
        }
        return nil
    }

    /// The thumbnail of `key` at the largest bucket below `bucket`, or nil: shown while the size asked for loads.
    public func entry(key: String, below bucket: Int) -> Entry? {
        let digest = Self.digest(key)
        for size in ImageSizeBucket.all.reversed() where size < bucket {
            if let found = read("\(digest)-\(size)", bucket: size) { return found }
        }
        return nil
    }

    private func read(_ name: String, bucket: Int) -> Entry? {
        guard let directory, var record = loadedIndex()[name] else { return nil }
        let file = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else {
            forget(name)
            return nil
        }
        let time = now()
        record.usedAt = time
        if time.timeIntervalSince(record.touchedAt) >= Self.touchInterval {
            record.touchedAt = time
            try? FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
        }
        index?[name] = record
        return Entry(data: data, bucket: bucket, storedAt: record.storedAt)
    }

    // MARK: Writing

    /// Keeps `data` as the thumbnail of `key` at `bucket`, stored at `storedAt` (when its bytes were fetched; now when
    /// nil), unless the caches were erased since `epoch` was read, or the picture was removed after those bytes were
    /// fetched (`remove(key:)`). The epoch is checked before the folder is made (a write from before an erase doesn't
    /// bring an empty folder back) and again after it: an erase that takes the folder away after that check takes this
    /// file with it, and one before it refuses the write.
    public func store(_ data: Data, key: String, bucket: Int, storedAt: Date? = nil, epoch captured: Int) {
        guard let directory, !data.isEmpty, data.count <= Self.maxEntryBytes, ImageSizeBucket.all.contains(bucket), epoch.value == captured else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard epoch.value == captured else { return }
        _ = loadedIndex()
        let time = now()
        let stored = min(storedAt ?? time, time)
        let digest = Self.digest(key)
        if let removed = removedAt[digest], stored < removed { return }
        let name = "\(digest)-\(bucket)"
        let file = directory.appendingPathComponent(name)
        do { try data.write(to: file, options: .atomic) } catch { return }
        try? FileManager.default.setAttributes([.creationDate: stored, .modificationDate: time], ofItemAtPath: file.path)
        if let old = index?[name] { total -= old.bytes }
        index?[name] = Record(bytes: data.count, storedAt: stored, usedAt: time, touchedAt: time)
        total += data.count
        if total > capacity { evict() }
    }

    /// Forgets every size of `key`: its sources no longer have it (`ImagePipeline`'s "gone"). A thumbnail of it fetched
    /// before now is refused from here on (`store`).
    public func remove(key: String) {
        guard let directory else { return }
        let digest = Self.digest(key)
        _ = loadedIndex()
        removedAt[digest] = now()
        for size in ImageSizeBucket.all {
            let name = "\(digest)-\(size)"
            guard loadedIndex()[name] != nil else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            forget(name)
        }
    }

    /// Forgets one size of `key` (a file that no longer decodes).
    public func remove(key: String, bucket: Int) {
        guard let directory else { return }
        let name = Self.fileName(key: key, bucket: bucket)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        forget(name)
    }

    /// The bytes the files take, as the index counts them.
    public var totalBytes: Int {
        _ = loadedIndex()
        return total
    }

    /// The number of files kept.
    public var count: Int { loadedIndex().count }

    private func forget(_ name: String) {
        if let old = index?.removeValue(forKey: name) { total -= old.bytes }
    }

    /// Deletes the least recently used files until the folder is under nine tenths of `capacity`.
    private func evict() {
        guard let directory, let index else { return }
        let target = capacity / 10 * 9
        for (name, _) in index.sorted(by: { $0.value.usedAt < $1.value.usedAt }) {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            forget(name)
        }
    }

    // MARK: The index

    /// The index, read from the folder the first time (and after an erase): every file named as this cache names
    /// them, with its size and dates; anything else in the folder (a write cut short) is deleted, and so is any folder
    /// an erase moved aside and didn't finish deleting.
    private func loadedIndex() -> [String: Record] {
        let current = epoch.value
        if let index, indexEpoch == current { return index }
        indexEpoch = current
        removedAt = [:]
        var loaded: [String: Record] = [:]
        total = 0
        if let directory {
            Self.deleteLeftovers(of: directory)
            let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isRegularFileKey]
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            for file in files {
                let values = try? file.resourceValues(forKeys: Set(keys))
                guard Self.parse(file.lastPathComponent) != nil, values?.isRegularFile == true, let bytes = values?.fileSize else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                let used = values?.contentModificationDate ?? .distantPast
                loaded[file.lastPathComponent] = Record(bytes: bytes, storedAt: values?.creationDate ?? .distantPast, usedAt: used, touchedAt: used)
                total += bytes
            }
        }
        index = loaded
        if total > capacity { evict() }
        return index ?? [:]
    }

    // MARK: Erasing

    /// Takes the folder away at once, from any thread (`ImagePipeline.removeAll`, on Delete Account and Forget This
    /// Device): renamed aside in one step, so no file in it can be read again, then deleted in the background. A write
    /// under way lands in the renamed folder, or finds no folder; the epoch, moved on before this, refuses every later
    /// one. A folder left aside by a launch that ended mid-delete is deleted the next time the cache is read.
    public nonisolated static func discardFiles(at directory: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        let aside = directory.deletingLastPathComponent().appendingPathComponent("\(directory.lastPathComponent).discarded-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.moveItem(at: directory, to: aside)
        } catch {
            try? manager.removeItem(at: directory) // could not be moved: deleted where it is
            return
        }
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: aside) }
    }

    private static func deleteLeftovers(of directory: URL) {
        let parent = directory.deletingLastPathComponent()
        let prefix = "\(directory.lastPathComponent).discarded-"
        for sibling in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where sibling.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(sibling))
        }
    }

    // MARK: Encoding

    /// A decoded thumbnail as the bytes a file keeps: JPEG at 0.85 for an opaque picture (a photo, a Moment's art), PNG
    /// when it has transparency (a logo cut out of its background), which JPEG would flatten onto black.
    public nonisolated static func encode(_ image: CGImage) -> Data? {
        let opaque: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (opaque ? "public.jpeg" : "public.png") as CFString, 1, nil) else { return nil }
        let options = opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
