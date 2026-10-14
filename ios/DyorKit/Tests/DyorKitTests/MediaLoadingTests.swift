import Foundation
import XCTest
@testable import DyorKit

/// Remote images load a few at a time (security audit 2026-09-26, RI-5). A load every viewer left is cancelled unless a
/// trusted download is under way: `ImagePipelineTests`.
final class MediaLoadingTests: XCTestCase {
    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0
        private(set) var peak = 0
        func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
        func leave() { lock.lock(); now -= 1; lock.unlock() }
    }

    func testTheLimiterRunsAtMostItsLimitAtOnce() async throws {
        let limiter = AsyncLimiter(2)
        let gauge = Gauge()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await limiter.run {
                        gauge.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        gauge.leave()
                        return i
                    }
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        XCTAssertEqual(results.sorted(), Array(0..<10))
        XCTAssertEqual(gauge.peak, 2)
    }

    func testAWaiterThatIsCancelledLeavesTheQueue() async throws {
        let limiter = AsyncLimiter(1)
        let release = AsyncStream<Void>.makeStream()
        let holder = Task { try await limiter.run { for await _ in release.stream { break }; return 0 } }
        try await Task.sleep(for: .milliseconds(50)) // the holder has the only slot
        let waiter = Task { try await limiter.run { 1 } }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("a cancelled waiter doesn't run")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        release.continuation.yield()
        _ = try await holder.value
        // The slot is free again for the next one.
        let next = try await limiter.run { 2 }
        XCTAssertEqual(next, 2)
    }

    /// The limiter says how many wait their turn: what the image pipeline's tests watch to see a request still queued.
    func testTheLimiterCountsThoseWaiting() async throws {
        let limiter = AsyncLimiter(1)
        let release = AsyncStream<Void>.makeStream()
        let holding = TestGate()
        let holder = Task { try await limiter.run { holding.open(); for await _ in release.stream { break }; return 0 } }
        await eventually("the holder has the slot") { holding.isOpen }
        let waiters = (1...2).map { value in Task { try await limiter.run { value } } }
        await eventually("both wait") { await limiter.queued == 2 }
        waiters[0].cancel()
        await eventually("a cancelled waiter leaves") { await limiter.queued == 1 }
        release.continuation.yield()
        _ = try await holder.value
        let second = try await waiters[1].value
        XCTAssertEqual(second, 2)
        let left = await limiter.queued
        XCTAssertEqual(left, 0)
    }

    // MARK: How a logo waits

    /// A logo shows its plain disc only for the grace period while it loads, then its letters; the letters at once when
    /// there is no URL or it failed (lately); the picture whenever there is one.
    func testALogoWaitsOnlyAMomentBeforeItsLetters() {
        typealias Wait = RemoteImageWait
        XCTAssertEqual(Wait.shown(hasImage: false, hasURL: true, failed: false, graceOver: false), .loading)
        XCTAssertEqual(Wait.shown(hasImage: false, hasURL: true, failed: false, graceOver: true), .standIn, "a slow or dead host")
        XCTAssertEqual(Wait.shown(hasImage: false, hasURL: true, failed: true, graceOver: false), .standIn, "failed, or failed lately")
        XCTAssertEqual(Wait.shown(hasImage: false, hasURL: false, failed: false, graceOver: false), .standIn, "no image")
        XCTAssertEqual(Wait.shown(hasImage: true, hasURL: true, failed: false, graceOver: true), .image, "late, but here")
        XCTAssertEqual(Wait.shown(hasImage: true, hasURL: true, failed: true, graceOver: false), .image)
        // A moment: long enough for a live host, far short of a dead one's 15 s.
        XCTAssertGreaterThanOrEqual(Wait.grace, .milliseconds(500))
        XCTAssertLessThanOrEqual(Wait.grace, .seconds(1))
    }

    /// A view draws the image it holds only for the picture it belongs to; given another picture, that picture from
    /// memory at once (whatever it held — an image or none), else nothing (its placeholder). Its stand-in shows for the
    /// picture it gave up on, one with no source, or one that failed lately — never because the last picture failed.
    func testAViewDrawsAndGivesUpOnlyForThePictureItIsGiven() {
        typealias Wait = RemoteImageWait
        XCTAssertEqual(Wait.drawn(held: "a", heldKey: "A", key: "A") { "memory" }, "a")
        XCTAssertNil(Wait.drawn(held: nil, heldKey: "A", key: "A") { "memory" } as String?, "its own picture: what it holds")
        XCTAssertEqual(Wait.drawn(held: "a", heldKey: "A", key: "B") { "b" }, "b", "another picture, from memory")
        XCTAssertEqual(Wait.drawn(held: nil, heldKey: nil, key: "B") { "b" }, "b", "even when it held no image")
        XCTAssertNil(Wait.drawn(held: "a", heldKey: "A", key: "B") { nil }, "never the last picture's")

        XCTAssertTrue(Wait.failed(failedKey: "A", key: "A", hasURL: true) { false })
        XCTAssertFalse(Wait.failed(failedKey: "A", key: "B", hasURL: true) { false }, "the last picture's failure isn't this one's")
        XCTAssertTrue(Wait.failed(failedKey: nil, key: "B", hasURL: true) { true }, "failed lately")
        XCTAssertTrue(Wait.failed(failedKey: nil, key: "B", hasURL: false) { false }, "nothing to load")
        XCTAssertFalse(Wait.failed(failedKey: nil, key: "B", hasURL: true) { false })
        // The spinner's wait: a picture from the phone arrives within it; a slow network doesn't.
        XCTAssertGreaterThanOrEqual(Wait.spinnerDelay, .milliseconds(150))
        XCTAssertLessThanOrEqual(Wait.spinnerDelay, .milliseconds(250))
    }

    func testTheGracePeriodEndsUnlessTheViewLeavesFirst() async {
        let over = await RemoteImageWait.graceElapses(.milliseconds(10))
        XCTAssertTrue(over)
        let left = Task { await RemoteImageWait.graceElapses(.seconds(30)) }
        left.cancel()
        let leftOver = await left.value
        XCTAssertFalse(leftOver, "a view that left, or changed URL, doesn't show its letters on the old wait")
    }

    /// A failed URL is remembered for its lifetime, then asked again; one that loaded is forgotten; run-out failures
    /// don't pile up.
    func testAFailedURLIsRememberedForAMinute() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var misses = RecentMisses()
        XCTAssertEqual(misses.lifetime, 60)
        XCTAssertFalse(misses.contains("a", now: start))
        misses.record("a", at: start)
        XCTAssertTrue(misses.contains("a", now: start))
        XCTAssertTrue(misses.contains("a", now: start + 59.9))
        XCTAssertFalse(misses.contains("a", now: start + 60), "asked again after a minute")
        XCTAssertEqual(misses.remaining("a", now: start + 15) ?? 0, 45, accuracy: 0.001, "how long until it may be asked again")
        XCTAssertNil(misses.remaining("a", now: start + 60))
        XCTAssertNil(misses.remaining("never", now: start))
        XCTAssertFalse(misses.contains("b", now: start))
        misses.record("b", at: start + 30)
        misses.remove("b")
        XCTAssertFalse(misses.contains("b", now: start + 31), "it loaded since")
        misses.record("c", at: start + 61)
        XCTAssertEqual(misses.count, 1, "a's run-out failure is dropped when another is recorded")
        XCTAssertTrue(misses.contains("c", now: start + 61))
    }
}
