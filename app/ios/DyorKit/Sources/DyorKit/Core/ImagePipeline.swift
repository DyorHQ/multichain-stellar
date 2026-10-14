import CoreGraphics
import Foundation

/// The sizes a remote image is decoded and kept at. A view asks for the bucket that covers its frame
/// (`bucket(points:)`), so a 34 pt row decodes a 96–192 px thumbnail, never the 1200 px one a Moment's page header needs,
/// and views of nearly the same size share one thumbnail in memory and on disk.
public enum ImageSizeBucket {
    /// The buckets, in pixels, smallest first: logos and rows (96, 192), avatars and news (256), NFT tiles (384), a
    /// board's card (512, 768 on the largest phones), a page header (1200).
    public static let all = [96, 192, 256, 384, 512, 768, 1200]
    /// The largest: a Moment's page header, full width on a 3× phone.
    public static let largest = 1200
    /// Pixels per point: every iPhone the app runs on draws at 3×, but the smallest (2×), which a 3× thumbnail covers.
    public static let scale: CGFloat = 3
    /// How far below the pixels needed a bucket may fall and still be chosen: a picture drawn at most 11 % larger than
    /// it was decoded doesn't look softer on a 3× screen, and a 34 pt row (102 px) then shares the 96 px logos.
    public static let tolerance = 0.9

    /// The smallest bucket at least `tolerance` of `pixels`; the largest bucket for anything bigger.
    public static func bucket(pixels: Int) -> Int {
        let needed = Double(max(pixels, 1)) * tolerance
        return all.first { Double($0) >= needed } ?? largest
    }

    /// The bucket for a frame whose longer side is `points` across.
    public static func bucket(points: CGFloat) -> Int {
        bucket(pixels: Int((max(points, 0) * scale).rounded(.up)))
    }

    /// The longer side, in pixels, to decode a `width` × `height` picture at so it covers a `bucket` × `bucket`
    /// square — what a frame filled by the picture needs whatever its shape: the shorter side reaches the bucket (the
    /// longer then goes past it by the picture's shape, at most twice over, so a panorama costs no more than 2 ×), and
    /// never past the picture's own size (no thumbnail is scaled up).
    public static func coverPixelSize(bucket: Int, width: Int, height: Int) -> Int {
        let longer = max(width, height), shorter = max(1, min(width, height))
        let aspect = min(Double(longer) / Double(shorter), 2)
        return max(1, min(longer, Int((Double(bucket) * aspect).rounded(.up))))
    }
}

/// A board's next rows, warmed ahead of the scroll (`ImagePipeline.prefetch`): when an item comes on screen, the pictures
/// of the `ahead` items after it load into memory and onto the phone, so they paint as they scroll in rather than start
/// loading then. The Moments and Launch boards.
public enum BoardPrefetch {
    /// How many items after the one that came on screen: three rows of a two-column grid. Also how many warm-ups are kept
    /// at once, the latest asked for: after a fling, the rows the scroll passed are dropped rather than worked through
    /// while the rows on screen wait.
    public static let ahead = 6

    /// The `ahead` items after the one whose id is `id` in `items`; none when it isn't there or is the last.
    public static func following<Item: Identifiable>(_ id: Item.ID, in items: [Item]) -> ArraySlice<Item> {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return [] }
        return items[(index + 1)...].prefix(ahead)
    }
}

/// How one source of a picture answered (`ImageSourceRace`).
public enum ImageAttemptResult: Sendable {
    /// Its bytes, fetched under the caps, hash-checked where the source asks for it, and readable as an image.
    case accepted(Data)
    /// Nothing usable. `gone`: the server said the picture isn't there, by what that host's answer means
    /// (`ImageSourcePolicy.saysGone`: a 404 anywhere, Storage's 400 on DyorHQ's host, never a 403) — as opposed to a
    /// timeout, a 429 or 5xx, a cut connection, or bytes the caps or the hash refused, which say nothing about whether
    /// the picture still exists.
    case failed(gone: Bool)
}

/// What a load in flight is allowed to do once every view waiting on it has left (`ImagePipeline`): a download from
/// DyorHQ's own host or one of the app's gateways already under way finishes into the cache (`markTrusted`), so a card
/// scrolled away and back doesn't start again from nothing; anything else is cancelled (security audit 2026-09-26,
/// RI-5). Once abandoned, its race starts nothing new; if that download then fails while a view has come back to the
/// load, the pipeline starts the load again for it (`ImagePipeline`).
public final class ImageLoadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var trusted = false
    private var abandoned = false
    private var onAbandon: (@Sendable () -> Void)?

    public init() {}

    /// A download from a host that may finish unwatched (`ImageSourcePolicy.mayFinishUnwatched`) has answered, or the
    /// accepted bytes came from one.
    public func markTrusted() {
        lock.lock()
        trusted = true
        lock.unlock()
    }

    /// Called when the last view waiting leaves: true — and the load is abandoned, going on only with what is under way —
    /// when a trusted download has answered; false when the caller must cancel it.
    public func abandonIfTrusted() -> Bool {
        lock.lock()
        guard trusted else { lock.unlock(); return false }
        abandoned = true
        let handler = onAbandon
        onAbandon = nil
        lock.unlock()
        handler?()
        return true
    }

    public var isAbandoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }

    /// Runs `handler` once the load is abandoned: at once when it already is.
    func whenAbandoned(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if abandoned { lock.unlock(); handler(); return }
        onAbandon = handler
        lock.unlock()
    }
}

/// Asks a picture's sources for it, best first, and the first one accepted wins. With `hedgeAfter` (the policy allows
/// it, `ImageSourcePolicy.mayRace`), a source whose request has gone out and that hasn't answered within that time is
/// joined by the next one, up to `maxInFlight` at once — a slow or dead host no longer holds the picture for its whole
/// timeout before the next is tried. The hedge's clock starts when the request is sent, not while it waits for a
/// download slot behind other pictures (`RemoteMedia.fetchSlots`), which says nothing about the source. Once a source
/// answers and is sending its bytes, it is the one asked: any other still silent stands down (it is cancelled, and asked
/// again in its turn if that one fails), so the same picture is never downloaded twice side by side. A source that fails
/// lets the next start at once. Without `hedgeAfter`, strictly one after another, as before.
public enum ImageSourceRace {
    public enum Outcome: Sendable {
        /// The bytes of the source at `index`.
        case accepted(index: Int, data: Data)
        /// No source was accepted. `gone`: every source was asked and each said the picture isn't there.
        /// `abandoned`: the load was abandoned or cancelled before every source was asked.
        case failed(gone: Bool, abandoned: Bool)
    }

    private enum Event: Sendable {
        case sent(Int)
        case responded(Int)
        case hedge(Int)
        case finished(Int, ImageAttemptResult)
        case abandoned
    }

    /// `attempt(index, sent, responded)` asks source `index`: it calls `sent` once its request has gone out (it has its
    /// download slot) and `responded` once its server has answered and its bytes are coming; a cancelled attempt answers
    /// `.failed(gone: false)`. `sleep` is the hedge's timer (a stand-in in tests).
    public static func run(count: Int, hedgeAfter: Duration?, maxInFlight: Int = 2, control: ImageLoadControl,
                           sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                           attempt: @escaping @Sendable (_ index: Int, _ sent: @escaping @Sendable () -> Void,
                                                         _ responded: @escaping @Sendable () -> Void) async -> ImageAttemptResult) async -> Outcome {
        guard count > 0 else { return .failed(gone: false, abandoned: false) }
        let limit = hedgeAfter == nil ? 1 : max(1, maxInFlight)
        let (events, sink) = AsyncStream<Event>.makeStream()
        /// Every attempt whose task hasn't reported yet, standing down or not.
        var attempts: [Int: Task<Void, Never>] = [:]
        var timers: [Int: Task<Void, Never>] = [:]
        var responded: Set<Int> = []
        /// Attempts cancelled because another source answered first: what they return says nothing of the picture.
        var standingDown: Set<Int> = []
        /// The sources not asked yet, and those stood down, best first.
        var queue = Array(0..<count)
        /// How many sources are asked at once: one, one more per hedge (up to `limit`), one again once a source answers.
        var wanted = 1
        var allGone = true
        var abandoned = false

        func running() -> Int { attempts.count - standingDown.count }
        /// Asks the best source in the queue that isn't still finishing an earlier attempt; false when there is none.
        func start() -> Bool {
            guard let position = queue.firstIndex(where: { attempts[$0] == nil }) else { return false }
            let index = queue.remove(at: position)
            attempts[index] = Task {
                let result = await attempt(index, { sink.yield(.sent(index)) }, { sink.yield(.responded(index)) })
                sink.yield(.finished(index, result))
            }
            return true
        }
        func fill() {
            while !abandoned, running() < wanted, start() {}
        }
        func standDown(_ index: Int) {
            attempts[index]?.cancel()
            timers.removeValue(forKey: index)?.cancel()
            standingDown.insert(index)
            queue.append(index)
            queue.sort()
        }
        func stop() {
            for task in attempts.values { task.cancel() }
            for timer in timers.values { timer.cancel() }
            sink.finish()
        }

        control.whenAbandoned { sink.yield(.abandoned) }
        return await withTaskCancellationHandler {
            fill()
            for await event in events {
                switch event {
                case .sent(let index):
                    // The hedge's clock starts now that the request is out.
                    guard let hedgeAfter, attempts[index] != nil, !standingDown.contains(index), !responded.contains(index) else { break }
                    timers[index] = Task {
                        guard (try? await sleep(hedgeAfter)) != nil else { return }
                        sink.yield(.hedge(index))
                    }
                case .responded(let index):
                    guard attempts[index] != nil, !standingDown.contains(index) else { break }
                    responded.insert(index)
                    timers.removeValue(forKey: index)?.cancel()
                    wanted = 1
                    // The source sending its bytes is the one asked: any other still silent stands down.
                    for other in attempts.keys where !responded.contains(other) && !standingDown.contains(other) { standDown(other) }
                case .hedge(let index):
                    guard !abandoned, attempts[index] != nil, !standingDown.contains(index), !responded.contains(index) else { break }
                    wanted = min(limit, running() + 1)
                    fill()
                case .finished(let index, .accepted(let data)):
                    attempts[index] = nil
                    stop()
                    return .accepted(index: index, data: data)
                case .finished(let index, .failed(let gone)):
                    attempts[index] = nil
                    timers.removeValue(forKey: index)?.cancel()
                    responded.remove(index)
                    if standingDown.remove(index) == nil, !gone { allGone = false }
                    fill()
                    if attempts.isEmpty {
                        stop()
                        return .failed(gone: allGone && !abandoned && queue.isEmpty, abandoned: abandoned || !queue.isEmpty)
                    }
                case .abandoned:
                    abandoned = true
                    // Only a download already sending its bytes goes on; the rest stop.
                    for (index, task) in attempts where !responded.contains(index) { task.cancel() }
                }
            }
            stop() // cancelled
            return .failed(gone: false, abandoned: true)
        } onCancel: {
            sink.finish()
        }
    }
}

/// Fetches one source's bytes: the network in the app (`network(policy:)`), a stand-in in tests. `sent` is called once
/// the request goes out — it has its download slot — and `responded` once the server answers 2xx within the cap
/// (`RemoteMedia.fetch`'s `onResponse`).
public struct ImageFetcher: Sendable {
    public let fetch: @Sendable (_ url: URL, _ maxBytes: Int, _ timeout: TimeInterval, _ sent: @escaping @Sendable () -> Void,
                                 _ responded: @escaping @Sendable () -> Void) async throws -> Data

    public init(fetch: @escaping @Sendable (_ url: URL, _ maxBytes: Int, _ timeout: TimeInterval, _ sent: @escaping @Sendable () -> Void,
                                            _ responded: @escaping @Sendable () -> Void) async throws -> Data) {
        self.fetch = fetch
    }

    /// Through `RemoteMedia.fetch` (https only, capped, no redirect to another host), a few at a time app-wide in the
    /// slots for its byte cap (`RemoteMedia.fetchSlots`: logo-sized downloads and Storage's resized copies apart from
    /// whole originals), `sent` once it has one. In a session that keeps nothing in `URLCache` (the pipeline keeps what
    /// it accepts): for DyorHQ's host and the app's gateways (`ImageSourcePolicy.mayFinishUnwatched`) `trustedSession`,
    /// whose transfers may take `RemoteMedia.trustedResourceTimeout`; for any other host `otherSession`, 30 s in all, so a
    /// server someone else runs can't trickle bytes to hold a slot.
    public static func network(policy: ImageSourcePolicy) -> ImageFetcher {
        ImageFetcher { url, maxBytes, timeout, sent, responded in
            let session = policy.mayFinishUnwatched(url) ? trustedSession : otherSession
            return try await RemoteMedia.fetchSlots(maxBytes: maxBytes).run {
                sent()
                return try await RemoteMedia.fetch(url, session: session, maxBytes: maxBytes, timeout: timeout, onResponse: responded)
            }
        }
    }

    /// The session for DyorHQ's host and the app's gateways: nothing stored, two minutes for a whole transfer.
    static let trustedSession = RemoteMedia.makeSession(resourceTimeout: RemoteMedia.trustedResourceTimeout, storesResponses: false)
    /// The session for any other host: nothing stored, 30 s for a whole transfer.
    static let otherSession = RemoteMedia.makeSession(storesResponses: false)
}

/// The one way the app loads an image from a host it doesn't control (security audit 2026-09-26, RI-5): coin logos,
/// launch and Moment artwork, avatars, NFT art, news thumbnails. A picture is its ordered sources (`ImageSourcePolicy`:
/// DyorHQ's bucket and the fixed IPFS gateways for anything a creator wrote; a source with a `keccak` counts only while
/// its bytes hash to it) and is shown at a size bucket (`ImageSizeBucket`).
///
/// Where a picture comes from, fastest first:
/// 1. **Memory** (`memoryImage`, synchronous, so a view seeds its first frame from it): decoded thumbnails, the size
///    asked for or larger, or a smaller one to show while that size loads.
/// 2. **The phone** (`stored`, no network): the thumbnail kept on disk (`ImageDiskCache`) at that size, or decoded down
///    from a larger one; else the bytes this session fetched for another size. A picture that can't change
///    (`ImageSourcePolicy.isImmutable`: write-once `launch-media`, an IPFS CID) is fresh for `immutableLifetime`, any
///    other for `mutableLifetime`; past that it still shows at once, and the view asks the network behind it.
/// 3. **The network** (`fetch`): one load per picture (and caps), shared by every view and every size that asks while it
///    runs — the bytes are fetched once and each size decoded from them. Sources are asked best first, joined by the
///    next when one is slow where the policy allows it (`ImageSourceRace`: counted from when its request went out; the
///    first to answer stands the others down), each with its host's timeout (`ImageSourcePolicy.requestTimeout`). Each
///    download is capped (`RemoteMedia.fetch`, `caps`), checked (`RemoteMedia.inspect`, the keccak), and decoded only as
///    a thumbnail, a few at a time app-wide (`RemoteMedia.decodes`). What is accepted goes to memory and to the disk. A
///    load every view left is cancelled, unless a download from DyorHQ's host or a gateway is already sending its bytes:
///    that one finishes into the cache (`ImageLoadControl`), and if it fails while a view has come back to the load, the
///    load starts again for that view. A load that failed is not asked again for `RecentMisses.lifetime`; one whose
///    every source said the picture isn't there (`ImageSourcePolicy.saysGone`, by what each host's answer means) takes
///    it out of memory and off the disk (a takedown reaches the phones that kept it).
///
/// A list-sized thumbnail (up to `maxRenderedBucket`) of an unchecked picture in DyorHQ's write-once `launch-media`
/// bucket asks Storage's resized copy of it at that size first (`ImageSourcePolicy.renderURL`), and the original only
/// if that copy fails: a few KB instead of the whole file. Those bytes answer for their size and smaller ones only, so
/// such a load is shared by the sizes it covers, and a larger size loads its own. A source with a `keccak` (a Moment
/// photo's mirror), an avatar, and the largest bucket (a Moment's page header, its share preview) always load the
/// original. A picture the app itself just uploaded (a new avatar) is drawn from the bytes it sent (`seed`).
///
/// A board warms its next rows ahead of the scroll (`prefetch`), two pictures at a time, from DyorHQ's hosts and the
/// gateways only, the latest batch only, and no whole original on a network that costs by the byte (`NetworkCost`); a
/// warm-up that fails is no miss for the views, which ask for themselves.
///
/// `removeAll` (Delete Account, Forget This Device) empties memory and disk at once, with no suspension, cancels every
/// warm-up, and nothing a load under way finishes afterwards is kept (`ImageCacheEpoch`).
@MainActor
public final class ImagePipeline {
    /// How long a picture that can't change is used from the phone before its sources are asked again — in the
    /// background, behind the copy on screen. Not never: a takedown deletes a `launch-media` object, and a phone that
    /// kept it must stop showing it.
    public nonisolated static let immutableLifetime: TimeInterval = 7 * 86_400
    /// How long any other picture (an avatar, a list's logo, a news photo) is used from the phone before it is asked
    /// again behind the copy on screen. A new avatar comes with a new `?v=` link, read from the original (never a resized
    /// copy a CDN may have kept by its path, `ImageSourcePolicy.renderURL`), so this matters only for a host that changes
    /// a picture in place.
    public nonisolated static let mutableLifetime: TimeInterval = 3_600
    /// How long a source may stay silent before the next joins it, where the policy allows it (`ImageSourceRace`):
    /// DyorHQ's hosts answer within about a second when they are up.
    public nonisolated static let hedgeAfter: Duration = .seconds(2)
    /// Decoded thumbnails kept in memory, by bitmap bytes.
    public nonisolated static let memoryBudget = 80 * 1024 * 1024
    /// Accepted downloads kept in memory, so another size of the same picture is decoded without asking again.
    public nonisolated static let bytesBudget = 32 * 1024 * 1024
    /// The largest size bucket loaded from Storage's resized copy of a picture in DyorHQ's write-once bucket
    /// (`ImageSourcePolicy.renderURL`): every list size — rows, logos, a board's card on the largest phones — but not a
    /// page header (`ImageSizeBucket.largest`), which keeps the original.
    public nonisolated static let maxRenderedBucket = 768
    /// The most bytes read for Storage's resized copy, under any caps: it is at most twice a list bucket across
    /// (`widerRender`) at quality 70 — tens to a few hundred KB — so it waits in the small downloads' slots
    /// (`RemoteMedia.fetchSlots`) rather than the few kept for whole originals; a copy larger than this is not what was
    /// asked for, and the original is asked next.
    public nonisolated static let maxRenderedBytes = RemoteMedia.smallImageBytes
    /// Pictures warmed ahead of a board's scroll at once, app-wide (`prefetch`): what is on screen keeps most of the
    /// download slots (`RemoteMedia.fetchSlots`).
    public nonisolated static let prefetches = AsyncLimiter(2)

    /// A picture in memory or on the phone. `exact`: at the size asked for or larger (else a smaller one to show while
    /// it loads). `fresh`: within its lifetime.
    public struct Shown {
        public let image: CGImage
        public let exact: Bool
        public let fresh: Bool
    }

    /// How a network load ended for one view.
    public enum Outcome {
        case image(CGImage)
        /// Every source said the picture isn't there: whatever was kept of it is gone too.
        case gone
        /// Nothing this time (a timeout, a refusal, a cancelled load): a copy already shown may stay.
        case failed
    }

    private final class Decoded {
        let image: CGImage
        let storedAt: Date
        init(image: CGImage, storedAt: Date) { self.image = image; self.storedAt = storedAt }
    }

    private final class Bytes {
        let data: Data
        let fetchedAt: Date
        let trusted: Bool
        /// The largest bucket they answer for: nil for a picture's original (any size), a bucket for Storage's resized
        /// copy at that size (`ImageSourcePolicy.renderURL`), which a larger size must not be decoded from.
        let covers: Int?
        init(data: Data, fetchedAt: Date, trusted: Bool, covers: Int?) {
            self.data = data; self.fetchedAt = fetchedAt; self.trusted = trusted; self.covers = covers
        }
        func answers(for bucket: Int) -> Bool { covers.map { $0 >= bucket } ?? true }
    }

    /// One request a load may make: a picture's source as it is (`render` nil), or Storage's resized copy of it at the
    /// `render` bucket (`ImageSourcePolicy.renderURL`), asked for first, whose bytes answer for that bucket and smaller.
    struct Ask: Sendable {
        let source: RemoteImageSource
        let render: Int?
        let url: URL
    }

    /// What one load asks for: the picture's sources under `caps`, Storage's resized copy at `render` first (nil: the
    /// originals only), and the keys it is found by — the picture's (`key`), the load's (`loadKey`), and the picture's
    /// under these caps (`pictureKey`), which a miss is remembered by.
    private struct LoadSpec: Sendable {
        let sources: [RemoteImageSource]
        let render: Int?
        let caps: RemoteMedia.Caps
        let key: String
        let loadKey: String
        let pictureKey: String
    }

    private final class Load {
        /// What the load may do once its views leave; a fresh one when it starts again (`failed`).
        var control = ImageLoadControl()
        var task: Task<Void, Never>?
        /// Sizes asked for and not decoded yet, in order, and the one being decoded.
        var pending: [Int] = []
        var decoding: Int?
        /// Sizes decoded so far, for a view that joins late.
        var decoded: [Int: CGImage] = [:]
        var waiters: [UUID: (bucket: Int, continuation: CheckedContinuation<Outcome, Never>)] = [:]
        /// The bytes are in: what is left is decoding, which no view leaving cancels.
        var hasBytes = false
        /// They came from DyorHQ's host or a gateway (`ImageSourcePolicy.mayFinishUnwatched`): every size asked for is
        /// decoded into the cache, whether or not its view is still there. From any other host, only the sizes a view
        /// still waits for.
        var trusted = false
        var cancelled = false
        /// A view waited on it at some point, not only a warm-up (`prefetch`): its failure is a miss the views go by.
        var watched = false
    }

    /// A warm-up queued or under way (`prefetch`): its task, cancelled when it is dropped or the caches are erased; a
    /// token telling it apart from a later warm-up of the same picture; and when it was last asked for.
    private struct Warming {
        let task: Task<Void, Never>
        let token: UUID
        var turn: Int
    }

    public let policy: ImageSourcePolicy
    public let disk: ImageDiskCache
    public let epoch: ImageCacheEpoch
    private let fetcher: ImageFetcher
    private let hedgeAfter: Duration
    private let isMetered: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let memory = NSCache<NSString, Decoded>()
    private let bytes = NSCache<NSString, Bytes>()
    private var misses = RecentMisses()
    /// Warm-ups that failed lately, by picture and caps: not warmed again for a minute — a card that scrolls in still
    /// asks for itself (`fetch`), which only `misses` stops.
    private var prefetchMisses = RecentMisses()
    private var loads: [String: Load] = [:]
    /// The pictures being warmed (`prefetch`), by size and load: each once at a time, the latest `BoardPrefetch.ahead`.
    private var prefetching: [String: Warming] = [:]
    private var prefetchTurn = 0

    /// `fetcher`: the network (`ImageFetcher.network`) unless a stand-in is given. `isMetered`: whether the network costs
    /// by the byte (`NetworkCost`), which stops whole originals being warmed.
    public init(policy: ImageSourcePolicy, directory: URL?, fetcher: ImageFetcher? = nil, capacity: Int = ImageDiskCache.defaultCapacity,
                hedgeAfter: Duration = ImagePipeline.hedgeAfter, isMetered: @escaping @Sendable () -> Bool = { NetworkCost.shared.isMetered },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.policy = policy
        let epoch = ImageCacheEpoch()
        self.epoch = epoch
        disk = ImageDiskCache(directory: directory, capacity: capacity, epoch: epoch, now: now)
        self.fetcher = fetcher ?? .network(policy: policy)
        self.hedgeAfter = hedgeAfter
        self.isMetered = isMetered
        self.now = now
        memory.totalCostLimit = Self.memoryBudget
        bytes.totalCostLimit = Self.bytesBudget
    }

    /// Starts, off the main thread, what the first pictures of a launch would otherwise wait for: the disk cache's index
    /// (a listing of its folder, which every read of the phone queues behind, `ImageDiskCache`), so a picture kept on
    /// the phone paints a moment after the first frame rather than after the listing; and the watch on the network's
    /// cost (`NetworkCost`). Called once, as the app starts.
    public func prepare() {
        let disk = self.disk
        Task.detached(priority: .userInitiated) { _ = await disk.count }
        _ = isMetered()
    }

    // MARK: Keys

    /// A picture's key: its ordered sources, each with the hash its bytes must match. Two Moments sharing a CID with
    /// different hashes or creators never share an entry, and a picture loaded under a hash check never answers for the
    /// same link without one.
    public nonisolated static func key(_ sources: [RemoteImageSource]) -> String {
        sources.map { source in
            source.url.absoluteString + (source.keccak.map { "#" + $0.map { String(format: "%02x", $0) }.joined() } ?? "")
        }.joined(separator: " ")
    }

    private static func memoryKey(_ key: String, _ bucket: Int) -> NSString { "\(bucket)|\(key)" as NSString }

    /// One network load per picture and per class of caps: a logo-sized view (2 MB) never waits on a full-size one's
    /// 10 MB download, nor the other way round. It is also what a miss is remembered by (`failedLately`), whatever size
    /// failed: a load fails only when the original did too.
    private static func loadKey(_ key: String, _ caps: RemoteMedia.Caps) -> String { "\(caps.maxBytes)/\(caps.maxSourcePixels)|\(key)" }

    /// A load of `pictureKey` (`loadKey`) that asks Storage's resized copy at `render` first has a key of its own: its
    /// bytes answer only for that size and smaller ones.
    private static func loadKey(_ pictureKey: String, render: Int?) -> String { render.map { "r\($0)|\(pictureKey)" } ?? pictureKey }

    /// The size a load of `sources` for `bucket` asks Storage's resized copy at: the bucket itself, when it is at most
    /// `maxRenderedBucket` and some source is an unchecked picture in DyorHQ's buckets (`ImageSourcePolicy.renderURL`);
    /// nil — the originals only — otherwise.
    nonisolated static func render(_ sources: [RemoteImageSource], bucket: Int, policy: ImageSourcePolicy) -> Int? {
        guard bucket <= maxRenderedBucket else { return nil }
        return sources.contains { $0.keccak == nil && policy.renderURL($0.url, width: bucket) != nil } ? bucket : nil
    }

    /// What a load asks, best first: each source as it is, preceded — for a load at a `render` size — by Storage's
    /// resized copy of it when it has one. A source with a `keccak` is always asked as it is: resized bytes can't be
    /// checked against the hash, and a Moment's mirror counts only when its bytes are (security audit 2026-09-26, PR-2).
    nonisolated static func asks(_ sources: [RemoteImageSource], render: Int?, policy: ImageSourcePolicy) -> [Ask] {
        sources.flatMap { source -> [Ask] in
            let original = Ask(source: source, render: nil, url: source.url)
            guard let render, source.keccak == nil, let resized = policy.renderURL(source.url, width: render) else { return [original] }
            return [Ask(source: source, render: render, url: resized), original]
        }
    }

    /// The width to ask Storage's resized copy again at, when the copy asked for at `bucket` pixels across came back
    /// `width` × `height` and doesn't cover a `bucket` square — a landscape picture, scaled to the bucket's width, whose
    /// height falls short by more than `ImageSizeBucket.tolerance`: the width at which its height reaches the bucket, at
    /// most twice the bucket (as `ImageSizeBucket.coverPixelSize`). Nil when it covers, or when the copy is narrower than
    /// asked (the original is that small: no larger copy exists, since Storage never enlarges).
    public nonisolated static func widerRender(width: Int, height: Int, bucket: Int) -> Int? {
        guard width >= bucket, height > 0, Double(height) < Double(bucket) * ImageSizeBucket.tolerance else { return nil }
        let wider = min(2 * bucket, Int((Double(bucket) * Double(width) / Double(height)).rounded(.up)))
        return wider > width ? wider : nil
    }

    /// How long a picture from `sources` is fresh: `immutableLifetime` when every source is one that can't change.
    public func lifetime(_ sources: [RemoteImageSource]) -> TimeInterval {
        !sources.isEmpty && sources.allSatisfy { policy.isImmutable($0.url) } ? Self.immutableLifetime : Self.mutableLifetime
    }

    // MARK: Memory

    /// The picture in memory: at `bucket` or larger (`exact`), else the largest smaller one. Synchronous, for a view's
    /// first frame.
    public func memoryImage(_ sources: [RemoteImageSource], bucket: Int) -> Shown? {
        guard !sources.isEmpty else { return nil }
        let key = Self.key(sources)
        let lifetime = self.lifetime(sources)
        let time = now()
        for size in ImageSizeBucket.all where size >= bucket {
            if let hit = memory.object(forKey: Self.memoryKey(key, size)) {
                return Shown(image: hit.image, exact: true, fresh: time.timeIntervalSince(hit.storedAt) < lifetime)
            }
        }
        for size in ImageSizeBucket.all.reversed() where size < bucket {
            if let hit = memory.object(forKey: Self.memoryKey(key, size)) {
                return Shown(image: hit.image, exact: false, fresh: time.timeIntervalSince(hit.storedAt) < lifetime)
            }
        }
        return nil
    }

    /// Whether a network load of `sources` under `caps` failed less than `RecentMisses.lifetime` ago: `fetch` would
    /// answer `.failed` without asking.
    public func failedLately(_ sources: [RemoteImageSource], caps: RemoteMedia.Caps) -> Bool {
        retryAfter(sources, caps: caps) != nil
    }

    /// How long until a network load of `sources` under `caps` that failed lately may be asked again; nil when it may
    /// now. A view still showing the picture's stand-in then asks once more (`RemoteImage`).
    public func retryAfter(_ sources: [RemoteImageSource], caps: RemoteMedia.Caps) -> TimeInterval? {
        misses.remaining(Self.loadKey(Self.key(sources), caps), now: now())
    }

    private func remember(_ image: CGImage, key: String, bucket: Int, storedAt: Date, epoch captured: Int) {
        guard epoch.value == captured else { return }
        memory.setObject(Decoded(image: image, storedAt: storedAt), forKey: Self.memoryKey(key, bucket), cost: Self.cost(image))
    }

    /// What a decoded thumbnail costs memory: its bitmap's bytes.
    public nonisolated static func cost(_ image: CGImage) -> Int { max(1, image.bytesPerRow * image.height) }

    // MARK: The phone

    /// The picture from memory or the phone, with no network: at `bucket` (`exact`) — from memory, from the disk at that
    /// size or decoded down from a larger one, or from the bytes this session fetched for another size (if they fit
    /// `caps`, and answer for this size: a resized copy only for its own and smaller) — else a smaller one kept on disk, to
    /// show while `bucket` loads. Nil when the phone has nothing of it.
    public func stored(_ sources: [RemoteImageSource], bucket: Int, caps: RemoteMedia.Caps) async -> Shown? {
        guard !sources.isEmpty else { return nil }
        let inMemory = memoryImage(sources, bucket: bucket)
        if let inMemory, inMemory.exact { return inMemory }
        let key = Self.key(sources)
        let lifetime = self.lifetime(sources)
        let captured = epoch.value
        let disk = self.disk
        func shown(_ image: CGImage, exact: Bool, storedAt: Date) -> Shown {
            Shown(image: image, exact: exact, fresh: now().timeIntervalSince(storedAt) < lifetime)
        }

        if let entry = await disk.entry(key: key, atLeast: bucket) {
            let derive = entry.bucket != bucket
            if let image = await Self.decodeStored(entry.data, bucket: bucket) {
                remember(image, key: key, bucket: bucket, storedAt: entry.storedAt, epoch: captured)
                if derive { Self.keep(image, key: key, bucket: bucket, storedAt: entry.storedAt, disk: disk, epoch: captured) }
                return shown(image, exact: true, storedAt: entry.storedAt)
            }
            await disk.remove(key: key, bucket: entry.bucket) // a file that no longer decodes
        }
        if let fetched = bytes.object(forKey: key as NSString), fetched.data.count <= caps.maxBytes, fetched.answers(for: bucket),
           let image = await Self.decodeRemote(fetched.data, bucket: bucket, caps: caps) {
            remember(image, key: key, bucket: bucket, storedAt: fetched.fetchedAt, epoch: captured)
            Self.keep(image, key: key, bucket: bucket, storedAt: fetched.fetchedAt, disk: disk, epoch: captured)
            return shown(image, exact: true, storedAt: fetched.fetchedAt)
        }
        if inMemory == nil, let entry = await disk.entry(key: key, below: bucket), let image = await Self.decodeStored(entry.data, bucket: entry.bucket) {
            remember(image, key: key, bucket: entry.bucket, storedAt: entry.storedAt, epoch: captured)
            return shown(image, exact: false, storedAt: entry.storedAt)
        }
        return inMemory
    }

    // MARK: The network

    /// The picture from its sources at `bucket`, under `caps`: one load per picture and caps, shared by every view and
    /// size that asks while it runs — for a list size asking Storage's resized copy (`maxRenderedBucket`), by every size
    /// that copy covers: a load already under way for this size or a larger one, or for the original, is joined.
    /// `.failed` at once for a load that failed lately (`failedLately`).
    public func fetch(_ sources: [RemoteImageSource], bucket: Int, caps: RemoteMedia.Caps) async -> Outcome {
        await fetch(sources, bucket: bucket, caps: caps, prefetch: false)
    }

    /// `fetch`, for a view or, `prefetch`, for a warm-up (`warm`): a load only warm-ups waited on is no miss for the
    /// views when it fails (`failed`).
    private func fetch(_ sources: [RemoteImageSource], bucket: Int, caps: RemoteMedia.Caps, prefetch: Bool) async -> Outcome {
        guard !sources.isEmpty else { return .failed }
        let key = Self.key(sources)
        let pictureKey = Self.loadKey(key, caps)
        if misses.contains(pictureKey, now: now()) { return .failed }
        let render = Self.render(sources, bucket: bucket, policy: policy)
        // Joinable: this load's own, a resized copy at a larger size (when this one is resized too), or the original's.
        let joinable = (render == nil ? [] : ImageSizeBucket.all.filter { $0 >= bucket && $0 <= Self.maxRenderedBucket }.map { Optional($0) }) + [nil]
        let load: Load
        let loadKey: String
        if let runningKey = joinable.map({ Self.loadKey(pictureKey, render: $0) }).first(where: { loads[$0] != nil }), let running = loads[runningKey] {
            load = running
            loadKey = runningKey
        } else {
            loadKey = Self.loadKey(pictureKey, render: render)
            load = Load()
            loads[loadKey] = load
            start(load, LoadSpec(sources: sources, render: render, caps: caps, key: key, loadKey: loadKey, pictureKey: pictureKey))
        }
        if !prefetch { load.watched = true }
        if let done = load.decoded[bucket] { return .image(done) }
        if !load.pending.contains(bucket), load.decoding != bucket { load.pending.append(bucket) }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                load.waiters[id] = (bucket, continuation)
                if Task.isCancelled { leave(load, loadKey: loadKey, waiter: id) }
            }
        } onCancel: {
            Task { @MainActor in self.leave(load, loadKey: loadKey, waiter: id) }
        }
    }

    /// One view leaves (it was cancelled: scrolled away, or its picture changed). The load goes on for any other still
    /// waiting; the last one out cancels it — unless its bytes are in (decoding finishes into the cache) or a trusted
    /// download is sending them (`ImageLoadControl.abandonIfTrusted`), which then goes on alone (RI-5: a download from
    /// any other host never outlives its last view).
    private func leave(_ load: Load, loadKey: String, waiter id: UUID) {
        guard let waiter = load.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: .failed)
        guard load.waiters.isEmpty, !load.hasBytes, !load.cancelled else { return }
        if load.control.abandonIfTrusted() { return }
        load.cancelled = true
        load.task?.cancel()
        if loads[loadKey] === load { loads[loadKey] = nil }
    }

    private func start(_ load: Load, _ spec: LoadSpec) {
        let captured = epoch.value
        let fetcher = self.fetcher
        let policy = self.policy
        let control = load.control
        let caps = spec.caps
        let asks = Self.asks(spec.sources, render: spec.render, policy: policy)
        let hedge = policy.mayRace(asks.map { RemoteImageSource(url: $0.url) }) ? hedgeAfter : nil
        // Bytes this session fetched for another size, while they are fresh and answer for every size this load may decode
        // (the original for a load of the original; for a resized one, a copy at least its size): a load for a stale
        // picture is a refresh, which asks the sources.
        let lifetime = self.lifetime(spec.sources)
        let reused = bytes.object(forKey: spec.key as NSString).flatMap {
            $0.data.count <= caps.maxBytes && (spec.render.map($0.answers(for:)) ?? ($0.covers == nil)) && self.now().timeIntervalSince($0.fetchedAt) < lifetime ? $0 : nil
        }
        let now = self.now
        let disk = self.disk
        load.task = Task.detached(priority: .userInitiated) { [weak self] in
            let accepted: (data: Data, fetchedAt: Date, trusted: Bool, covers: Int?)
            if let reused {
                accepted = (reused.data, reused.fetchedAt, reused.trusted, reused.covers)
            } else {
                let outcome = await ImageSourceRace.run(count: asks.count, hedgeAfter: hedge, control: control) { index, sent, responded in
                    let ask = asks[index]
                    let trusted = policy.mayFinishUnwatched(ask.url)
                    return await Self.attempt(ask, caps: caps, timeout: policy.requestTimeout(for: ask.url), fetcher: fetcher, policy: policy, sent: sent) {
                        if trusted { control.markTrusted() }
                        responded()
                    }
                }
                switch outcome {
                case .accepted(let index, let data):
                    accepted = (data, now(), policy.mayFinishUnwatched(asks[index].url), asks[index].render)
                case .failed(let gone, let abandoned):
                    await self?.failed(load, spec, gone: gone, abandoned: abandoned || Task.isCancelled)
                    return
                }
            }
            if accepted.trusted { control.markTrusted() }
            guard let self, await self.received(load, accepted.data, key: spec.key, fetchedAt: accepted.fetchedAt, trusted: accepted.trusted, covers: accepted.covers,
                                                 lifetime: lifetime, pictureKey: spec.pictureKey, epoch: captured) else { return }
            // Each size asked for, the first first, until none is left; a size asked for meanwhile joins the queue.
            while let bucket = await self.nextBucket(load, loadKey: spec.loadKey) {
                guard !Task.isCancelled, let image = await Self.decodeRemote(accepted.data, bucket: bucket, caps: caps) else {
                    await self.decoded(load, nil, key: spec.key, bucket: bucket, loadKey: spec.loadKey, storedAt: accepted.fetchedAt, epoch: captured)
                    continue
                }
                await self.decoded(load, image, key: spec.key, bucket: bucket, loadKey: spec.loadKey, storedAt: accepted.fetchedAt, epoch: captured)
                Self.keep(image, key: spec.key, bucket: bucket, storedAt: accepted.fetchedAt, disk: disk, epoch: captured)
            }
        }
    }

    /// One request, asked: fetched under the caps with its host's timeout — Storage's resized copy under
    /// `maxRenderedBytes`, so it waits in the small downloads' slots — then kept only when its bytes hash to the source's
    /// `keccak` (a swapped mirror falls through to IPFS) and read as an image within the caps (an HTML page, an SVG or
    /// garbage falls through to the next). A refusal says the picture is gone only where its host's answer means that
    /// (`ImageSourcePolicy.saysGone`). Storage's resized copy of a landscape picture whose height falls short of its
    /// bucket is asked again at the width that covers it (`widerRender`), and the first copy kept if that fails.
    private nonisolated static func attempt(_ ask: Ask, caps: RemoteMedia.Caps, timeout: TimeInterval, fetcher: ImageFetcher, policy: ImageSourcePolicy,
                                            sent: @escaping @Sendable () -> Void, responded: @escaping @Sendable () -> Void) async -> ImageAttemptResult {
        let maxBytes = ask.render == nil ? caps.maxBytes : min(caps.maxBytes, maxRenderedBytes)
        let data: Data
        do {
            data = try await fetcher.fetch(ask.url, maxBytes, timeout, sent, responded)
        } catch RemoteMedia.Failure.status(let status) {
            return .failed(gone: policy.saysGone(status, from: ask.url))
        } catch {
            return .failed(gone: false)
        }
        guard !Task.isCancelled else { return .failed(gone: false) }
        if let keccak = ask.source.keccak, Keccak.hash256(data) != keccak { return .failed(gone: false) }
        guard let size = try? RemoteMedia.inspect(data, maxSourcePixels: caps.maxSourcePixels) else { return .failed(gone: false) }
        guard let bucket = ask.render, let wider = widerRender(width: size.width, height: size.height, bucket: bucket),
              let again = policy.renderURL(ask.source.url, width: wider) else { return .accepted(data) }
        guard let covering = try? await fetcher.fetch(again, maxBytes, timeout, {}, {}), !Task.isCancelled,
              (try? RemoteMedia.inspect(covering, maxSourcePixels: caps.maxSourcePixels)) != nil else { return .accepted(data) }
        return .accepted(covering)
    }

    /// The bytes are in: kept for the other sizes they answer for (unless the caches were erased since the load began) —
    /// never in place of fresh bytes that answer for more (a resized copy over the original) — and the picture is no
    /// longer a miss. False when the load was cancelled meanwhile.
    private func received(_ load: Load, _ data: Data, key: String, fetchedAt: Date, trusted: Bool, covers: Int?, lifetime: TimeInterval,
                          pictureKey: String, epoch captured: Int) -> Bool {
        guard !load.cancelled else { return false }
        load.hasBytes = true
        load.trusted = trusted
        if epoch.value == captured {
            var keptAnswersForMore = false
            if let covers, let kept = bytes.object(forKey: key as NSString), now().timeIntervalSince(kept.fetchedAt) < lifetime {
                keptAnswersForMore = kept.covers.map { $0 > covers } ?? true
            }
            if !keptAnswersForMore {
                bytes.setObject(Bytes(data: data, fetchedAt: fetchedAt, trusted: trusted, covers: covers), forKey: key as NSString, cost: data.count)
            }
        }
        misses.remove(pictureKey)
        return true
    }

    /// The next size to decode, or nil — and the load is over, so the next view to ask starts afresh from the caches.
    /// A size whose views all left is skipped unless the bytes are trusted (`Load.trusted`).
    private func nextBucket(_ load: Load, loadKey: String) -> Int? {
        load.decoding = nil
        while !load.pending.isEmpty {
            let bucket = load.pending.removeFirst()
            if load.trusted || load.waiters.values.contains(where: { $0.bucket == bucket }) {
                load.decoding = bucket
                return bucket
            }
        }
        retire(load, loadKey: loadKey)
        return nil
    }

    /// One size decoded (nil: it didn't decode): its views answered, and the load retired at once when no other size
    /// waits, so a view asking a moment later starts afresh — from the caches, or from the network for a picture whose
    /// lifetime ran out — rather than joining a load that is over.
    private func decoded(_ load: Load, _ image: CGImage?, key: String, bucket: Int, loadKey: String, storedAt: Date, epoch captured: Int) {
        if let image {
            remember(image, key: key, bucket: bucket, storedAt: storedAt, epoch: captured)
            load.decoded[bucket] = image
        }
        load.decoding = nil
        resolve(load, bucket: bucket, with: image.map { .image($0) } ?? .failed)
        if load.pending.isEmpty { retire(load, loadKey: loadKey) }
    }

    private func retire(_ load: Load, loadKey: String) {
        if loads[loadKey] === load { loads[loadKey] = nil }
    }

    /// No source was accepted. `gone`: every source said the picture isn't there, so whatever was kept of it goes too.
    /// `abandoned`: the load was abandoned or cancelled before every source was asked, which is no miss — and a load left
    /// to a trusted download (every view had gone, `ImageLoadControl`) that a view came back to meanwhile starts again
    /// for it, from its first source, rather than answer it `.failed` with sources never asked. A miss is the picture's
    /// under these caps (`pictureKey`), whatever size failed: the original was asked too. A load only warm-ups waited on
    /// (`Load.watched` false) is no miss for the views — a card that scrolls in asks for itself — only for the warm-ups
    /// (`prefetchMisses`).
    private func failed(_ load: Load, _ spec: LoadSpec, gone: Bool, abandoned: Bool) async {
        if abandoned, !load.cancelled, !load.waiters.isEmpty, loads[spec.loadKey] === load {
            // The same load, with its views and sizes (a view leaving finds it), under a control not abandoned.
            load.control = ImageLoadControl()
            start(load, spec)
            return
        }
        if loads[spec.loadKey] === load { loads[spec.loadKey] = nil }
        if !abandoned, !load.cancelled {
            if load.watched { misses.record(spec.pictureKey, at: now()) } else { prefetchMisses.record(spec.pictureKey, at: now()) }
        }
        if gone {
            for size in ImageSizeBucket.all { memory.removeObject(forKey: Self.memoryKey(spec.key, size)) }
            bytes.removeObject(forKey: spec.key as NSString)
        }
        for (id, waiter) in load.waiters {
            load.waiters[id] = nil
            waiter.continuation.resume(returning: gone ? .gone : .failed)
        }
        if gone { await disk.remove(key: spec.key) }
    }

    private func resolve(_ load: Load, bucket: Int, with outcome: Outcome) {
        for (id, waiter) in load.waiters where waiter.bucket == bucket {
            load.waiters[id] = nil
            waiter.continuation.resume(returning: outcome)
        }
    }

    // MARK: Warming

    /// Loads the picture of `sources` at `bucket` under `caps` — what a view showing it at that size will ask for — into
    /// memory and onto the phone ahead of that view, so a board's next rows paint as they scroll in (`prefetch` after the
    /// item on screen). From the phone when it has the picture, else the network, `prefetches` at a time app-wide, and
    /// once at a time per picture; nothing for a picture already in memory at that size and fresh, or one that failed
    /// lately. Only a picture all of whose sources may finish with nobody looking (`ImageSourcePolicy.mayFinishUnwatched`:
    /// DyorHQ's host and the app's gateways): no other host is asked for a picture nobody is looking at (security audit
    /// 2026-09-26, RI-5). A view that asks meanwhile joins the load; nothing is shown that a view didn't ask for.
    ///
    /// Only the latest `BoardPrefetch.ahead` asked for are kept: an older one — a row the scroll has passed — is cancelled,
    /// queued or under way (its view, if it is on screen, has its own load), so after a fling the slots go to the rows
    /// ahead. A whole original (no resized copy: a Moment's hash-checked photo, up to several MB) isn't warmed on a network
    /// that costs by the byte (`isMetered`); its card still loads it as it scrolls in.
    public func prefetch(_ sources: [RemoteImageSource], bucket: Int, caps: RemoteMedia.Caps) {
        guard !sources.isEmpty, sources.allSatisfy({ policy.mayFinishUnwatched($0.url) }) else { return }
        if let shown = memoryImage(sources, bucket: bucket), shown.exact, shown.fresh { return }
        let pictureKey = Self.loadKey(Self.key(sources), caps)
        guard !misses.contains(pictureKey, now: now()), !prefetchMisses.contains(pictureKey, now: now()) else { return }
        if Self.render(sources, bucket: bucket, policy: policy) == nil, caps.maxBytes > RemoteMedia.smallImageBytes, isMetered() { return }
        let id = "\(bucket)|" + pictureKey
        prefetchTurn += 1
        if prefetching[id] != nil {
            prefetching[id]?.turn = prefetchTurn
            return
        }
        // The epoch now: a warm-up still queued when the caches are erased keeps nothing (`warm`).
        let captured = epoch.value
        let token = UUID()
        let task = Task(priority: .utility) { [weak self] in
            _ = try? await Self.prefetches.run { [weak self] in await self?.warm(sources, bucket: bucket, caps: caps, epoch: captured) }
            if self?.prefetching[id]?.token == token { self?.prefetching[id] = nil }
        }
        prefetching[id] = Warming(task: task, token: token, turn: prefetchTurn)
        let excess = prefetching.count - BoardPrefetch.ahead
        guard excess > 0 else { return }
        for (stale, warming) in prefetching.sorted(by: { $0.value.turn < $1.value.turn }).prefix(excess) {
            warming.task.cancel() // a waiter for a slot leaves the queue (`AsyncLimiter`); a load under way loses this waiter
            prefetching[stale] = nil
        }
    }

    /// The warm-ups queued or under way.
    var warming: Int { prefetching.count }

    /// One prefetch, once its turn comes: nothing when the picture is in memory or on the phone at that size and fresh
    /// (decoded into memory on the way), else the network. Nothing at all once the caches were erased after it was asked
    /// for (`captured`): `removeAll` cancels it too, and `stored` and `fetch` read the epoch they keep under as they
    /// begin, right after each check here, with no suspension between.
    private func warm(_ sources: [RemoteImageSource], bucket: Int, caps: RemoteMedia.Caps, epoch captured: Int) async {
        guard epoch.value == captured, !Task.isCancelled else { return }
        if let kept = await stored(sources, bucket: bucket, caps: caps), kept.exact, kept.fresh { return }
        let pictureKey = Self.loadKey(Self.key(sources), caps)
        guard epoch.value == captured, !Task.isCancelled, !misses.contains(pictureKey, now: now()),
              !prefetchMisses.contains(pictureKey, now: now()) else { return }
        _ = await fetch(sources, bucket: bucket, caps: caps, prefetch: true)
    }

    // MARK: Pictures the app uploaded

    /// Keeps `data` — bytes the app itself just uploaded to DyorHQ's host (a new avatar) — as the picture of `sources`,
    /// fetched now: its views draw it at once, every size decoded from these bytes (`stored`), with no read back from the
    /// network. Only for unchecked sources on DyorHQ's host (a hash-checked source counts only for bytes that hash to it,
    /// PR-2), and only bytes a download would pass (`RemoteMedia.inspect` under the full caps).
    public func seed(_ data: Data, for sources: [RemoteImageSource]) {
        guard !sources.isEmpty, sources.allSatisfy({ $0.keccak == nil && policy.isFirstParty($0.url) }), data.count <= RemoteMedia.maxImageBytes,
              (try? RemoteMedia.inspect(data)) != nil else { return }
        let key = Self.key(sources)
        for size in ImageSizeBucket.all { memory.removeObject(forKey: Self.memoryKey(key, size)) }
        bytes.setObject(Bytes(data: data, fetchedAt: now(), trusted: true, covers: nil), forKey: key as NSString, cost: data.count)
        for bucket in [RemoteMedia.smallThumbnail, ImageSizeBucket.largest] { misses.remove(Self.loadKey(key, RemoteMedia.caps(forThumbnail: bucket))) }
    }

    // MARK: Decoding and keeping

    /// Remote bytes as a thumbnail covering `bucket` (`ImageSizeBucket.coverPixelSize`), under the caps' pixel limit,
    /// off the main thread and a few at a time app-wide (`RemoteMedia.decodes`): an image ImageIO can't subsample (a
    /// PNG) may need its full bitmap.
    private nonisolated static func decodeRemote(_ data: Data, bucket: Int, caps: RemoteMedia.Caps) async -> CGImage? {
        try? await RemoteMedia.decodes.run {
            let size = try RemoteMedia.inspect(data, maxSourcePixels: caps.maxSourcePixels)
            return try RemoteMedia.thumbnail(data, maxPixelSize: ImageSizeBucket.coverPixelSize(bucket: bucket, width: size.width, height: size.height),
                                             maxSourcePixels: caps.maxSourcePixels)
        }
    }

    /// A kept thumbnail (the app's own JPEG or PNG, at most a 1200 px bucket's size), decoded off the main thread for
    /// `bucket` — as it is, or down from a larger bucket. Outside `RemoteMedia.decodes`: it is small and bounded, so a
    /// screen of kept pictures paints while large remote decodes run.
    private nonisolated static func decodeStored(_ data: Data, bucket: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let size = try? RemoteMedia.inspect(data) else { return nil }
            return try? RemoteMedia.thumbnail(data, maxPixelSize: ImageSizeBucket.coverPixelSize(bucket: bucket, width: size.width, height: size.height))
        }.value
    }

    /// Writes a decoded thumbnail to the disk in the background: encoding and the write never hold up a view.
    private nonisolated static func keep(_ image: CGImage, key: String, bucket: Int, storedAt: Date, disk: ImageDiskCache, epoch captured: Int) {
        Task.detached(priority: .utility) {
            guard let data = ImageDiskCache.encode(image) else { return }
            await disk.store(data, key: key, bucket: bucket, storedAt: storedAt, epoch: captured)
        }
    }

    // MARK: Erasing

    /// Forgets every picture and every miss, in memory and on disk, at once (Delete Account, Forget This Device):
    /// nothing on the phone shows which pictures it loaded once the account is gone. Synchronous — the erase has no
    /// suspension between its wipe and the sign-out. Every warm-up, queued or under way, is cancelled (and one that
    /// runs anyway keeps nothing, `warm`). Loads under way still answer the views that wait on them, but nothing they
    /// finish is kept (`ImageCacheEpoch`).
    public func removeAll() {
        epoch.advance()
        memory.removeAllObjects()
        bytes.removeAllObjects()
        misses = RecentMisses()
        prefetchMisses = RecentMisses()
        for warming in prefetching.values { warming.task.cancel() }
        prefetching = [:]
        if let directory = disk.directory { ImageDiskCache.discardFiles(at: directory) }
    }
}
