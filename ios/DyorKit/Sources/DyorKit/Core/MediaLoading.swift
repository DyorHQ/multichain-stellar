import Foundation

/// Runs at most `limit` operations at once; the rest wait their turn, first come first served (security audit
/// 2026-09-26, RI-5: a screen full of hostile images must not download and decode all of them at the same time). A
/// waiter whose task is cancelled leaves the queue at once and throws `CancellationError`.
public actor AsyncLimiter {
    public let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(_ limit: Int) { self.limit = max(1, limit) }

    /// The operations waiting their turn.
    public var queued: Int { waiting.count }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Resumed by `release`, which handed its slot over: `running` already counts this one.
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().continuation.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return } // already handed a slot
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// How a small remote image with letters to stand in for it (a coin logo, a chain badge) waits for its picture. A plain
/// disc for a short grace period, in which a logo from a live host usually arrives (from the phone, within a frame or
/// two: `ImagePipeline`), so the letters don't flash first; then the letters while the load goes on, since a dead host
/// holds a download for up to 15 s and eight run at once app-wide (`RemoteMedia.fetches`), so a list of them could
/// otherwise sit empty for most of a minute; and the letters at once for a URL that failed a moment ago
/// (`RecentMisses`). The picture takes the place of either as soon as it arrives.
public enum RemoteImageWait {
    /// How long the plain disc shows before the letters.
    public static let grace: Duration = .milliseconds(800)
    /// How long a picture with no letters to stand in for it (a Moment's art, a launch's, an avatar, an NFT) shows its
    /// plain fill before a spinner: a picture kept on the phone arrives within it — after a relaunch memory is empty, and
    /// the phone answers a moment later — so it never flashes a spinner first.
    public static let spinnerDelay: Duration = .milliseconds(200)

    /// What a view waiting on a remote image shows.
    public enum Shown: Equatable, Sendable {
        /// The picture.
        case image
        /// The loading placeholder: the plain disc, or a spinner in a view with no letters (and no grace period).
        case loading
        /// The letters, or whatever else stands in for a picture there is none of.
        case standIn
    }

    /// What to show. `failed`: the load answered nothing, or the URL failed a moment ago. `graceOver`: the load has gone
    /// on for the view's grace period (never, in a view without one).
    public static func shown(hasImage: Bool, hasURL: Bool, failed: Bool, graceOver: Bool) -> Shown {
        if hasImage { return .image }
        return hasURL && !failed && !graceOver ? .loading : .standIn
    }

    /// The image a view draws for the picture whose key is `key`: the one it holds when it belongs to that picture
    /// (`heldKey`), else the picture from memory (`inMemory`) — a view just given another picture draws that one at once
    /// when the app has it, whatever it held before (an image, or none) — never the last picture's.
    public static func drawn<Image>(held: Image?, heldKey: String?, key: String, inMemory: () -> Image?) -> Image? {
        heldKey == key ? held : inMemory()
    }

    /// Whether a view shows its stand-in for the picture whose key is `key` rather than wait for it: the view gave up on
    /// that very picture (`failedKey`), it has no source, or its load failed lately (`failedLately`) — never because an
    /// earlier picture the view showed failed.
    public static func failed(failedKey: String?, key: String, hasURL: Bool, failedLately: () -> Bool) -> Bool {
        failedKey == key || !hasURL || failedLately()
    }

    /// Waits out `grace`: true once it has passed, false when the wait was cancelled first (the view left, or its URL
    /// changed).
    public static func graceElapses(_ grace: Duration = grace) async -> Bool {
        do {
            try await Task.sleep(for: grace)
            return true
        } catch {
            return false
        }
    }
}

/// The image loads that failed lately, each remembered for `lifetime` seconds: a dead host isn't asked again for every
/// row that shows its logo, and those rows show their letters at once.
public struct RecentMisses: Sendable {
    public let lifetime: TimeInterval
    private var failedAt: [String: Date] = [:]

    public init(lifetime: TimeInterval = 60) { self.lifetime = lifetime }

    /// Whether `key` failed less than `lifetime` before `now`.
    public func contains(_ key: String, now: Date = Date()) -> Bool {
        remaining(key, now: now) != nil
    }

    /// How long until `key` may be asked again, when it failed less than `lifetime` before `now`; nil when it may now.
    public func remaining(_ key: String, now: Date = Date()) -> TimeInterval? {
        guard let failed = failedAt[key] else { return nil }
        let left = lifetime - now.timeIntervalSince(failed)
        return left > 0 ? left : nil
    }

    /// Records that `key` failed at `now`, and forgets the failures that have run out.
    public mutating func record(_ key: String, at now: Date = Date()) {
        failedAt = failedAt.filter { now.timeIntervalSince($0.value) < lifetime }
        failedAt[key] = now
    }

    /// Forgets that `key` failed: it has loaded since.
    public mutating func remove(_ key: String) { failedAt[key] = nil }

    /// The failures remembered, run out or not.
    public var count: Int { failedAt.count }
}
