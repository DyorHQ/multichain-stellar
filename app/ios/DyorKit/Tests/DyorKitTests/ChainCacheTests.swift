import Foundation
import XCTest
@testable import DyorKit

/// The reads the app's screens share (`ChainCache`): callers asking at once share one read, an answer is kept for its
/// time only, a failure is shared but never kept, and an invalidation (a transaction that settled, a pull to refresh, an
/// erase) means the next read goes to the chain, with nothing read before it joined or kept. And what never changes is kept
/// on the device (`ChainStore`) until an erase, which no write read before it outlives.
final class ChainCacheTests: XCTestCase {
    /// A read that waits until the test lets it answer, and counts how often it was started.
    private actor Held {
        private(set) var started = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var open = false

        func read(_ value: Int) async -> Int {
            started += 1
            if !open { await withCheckedContinuation { waiting.append($0) } }
            return value
        }

        func release() {
            open = true
            for waiter in waiting { waiter.resume() }
            waiting = []
        }

        /// Waits until `count` reads have started.
        func untilStarted(_ count: Int) async {
            while started < count { await Task.yield() }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return time
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            time += seconds
            lock.unlock()
        }
    }

    private struct Failure: Error {}

    // MARK: Sharing

    func testCallersAskingAtOnceShareOneRead() async throws {
        let cache = ChainCache()
        let held = Held()
        let answers = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { (try? await cache.value("list", ttl: 15) { await held.read(7) }) ?? -1 }
            }
            await held.untilStarted(1)
            await held.release()
            var out: [Int] = []
            for await answer in group { out.append(answer) }
            return out
        }
        XCTAssertEqual(answers, Array(repeating: 7, count: 8))
        let started = await held.started
        XCTAssertEqual(started, 1, "one read for every caller")
    }

    func testAnAnswerIsKeptForItsTimeOnly() async throws {
        let clock = Clock()
        let cache = ChainCache(now: { clock.now })
        let held = Held()
        await held.release()
        var value = try await cache.value("list", ttl: 15) { await held.read(1) }
        XCTAssertEqual(value, 1)
        clock.advance(14)
        value = try await cache.value("list", ttl: 15) { await held.read(2) }
        XCTAssertEqual(value, 1, "kept within its time")
        var started = await held.started
        XCTAssertEqual(started, 1)
        clock.advance(1)
        value = try await cache.value("list", ttl: 15) { await held.read(3) }
        XCTAssertEqual(value, 3, "read again once its time is up")
        started = await held.started
        XCTAssertEqual(started, 2)
    }

    /// A clock set back makes an answer seem younger: it is read again rather than kept longer.
    func testAClockSetBackNeverKeepsAnAnswerLonger() async throws {
        let clock = Clock()
        let cache = ChainCache(now: { clock.now })
        _ = try await cache.value("list", ttl: 15) { 1 }
        clock.advance(-60)
        let value = try await cache.value("list", ttl: 15) { 2 }
        XCTAssertEqual(value, 2)
    }

    func testAFailureIsSharedButNeverKept() async throws {
        let cache = ChainCache()
        let held = Held()
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        _ = try await cache.value("list", ttl: 15) { () async throws -> Int in
                            _ = await held.read(0)
                            throw Failure()
                        }
                        return true
                    } catch {
                        return false
                    }
                }
            }
            await held.untilStarted(1)
            await held.release()
            var out: [Bool] = []
            for await outcome in group { out.append(outcome) }
            return out
        }
        XCTAssertEqual(outcomes, [false, false, false], "every caller waiting gets the failure")
        var started = await held.started
        XCTAssertEqual(started, 1)
        let value = try await cache.value("list", ttl: 15) { await held.read(5) }
        XCTAssertEqual(value, 5, "and the next read goes to the chain")
        started = await held.started
        XCTAssertEqual(started, 2)
    }

    /// An answer `keep` refuses (a list that couldn't be read in full) is shared with those waiting, never kept.
    func testAnAnswerNotToKeepIsReadAgain() async throws {
        let cache = ChainCache()
        let held = Held()
        await held.release()
        let first = try await cache.value("list", ttl: 15, keep: { (value: Int) in value > 1 }) { await held.read(1) }
        let second = try await cache.value("list", ttl: 15, keep: { (value: Int) in value > 1 }) { await held.read(2) }
        let third = try await cache.value("list", ttl: 15, keep: { (value: Int) in value > 1 }) { await held.read(3) }
        XCTAssertEqual([first, second, third], [1, 2, 2], "the first answer wasn't kept, the second was")
        let started = await held.started
        XCTAssertEqual(started, 2)
    }

    /// After an invalidation nobody joins a read begun before it, nothing it brings back is kept, and the read after it is
    /// what the next callers share.
    func testAnInvalidationReadsAgainAndKeepsNothingReadBeforeIt() async throws {
        let cache = ChainCache()
        let before = Held()
        async let early = cache.value("list", ttl: 15) { await before.read(1) }
        await before.untilStarted(1)
        cache.invalidate()
        let after = Held()
        await after.release()
        let late = try await cache.value("list", ttl: 15) { await after.read(2) }
        XCTAssertEqual(late, 2, "not joined to the read begun before the invalidation")
        await before.release()
        let earlyValue = try await early
        XCTAssertEqual(earlyValue, 1, "which still answers the caller that asked before it")
        let next = try await cache.value("list", ttl: 15) { await after.read(3) }
        XCTAssertEqual(next, 2, "the read after the invalidation is the one kept")
        let started = await after.started
        XCTAssertEqual(started, 1)

        cache.invalidate()
        let fresh = try await cache.value("list", ttl: 15) { await after.read(4) }
        XCTAssertEqual(fresh, 4, "an answer kept is forgotten")
    }

    /// The part-by-part keeping a price read uses: a part read before an invalidation is never kept after it.
    func testPartsKeptOneByOneFollowTheInvalidations() {
        let clock = Clock()
        let cache = ChainCache(now: { clock.now })
        let since = cache.generation
        cache.keep(1.5, for: "price.a", readSince: since)
        XCTAssertEqual(cache.fresh("price.a", ttl: 10) as Double?, 1.5)
        clock.advance(10)
        XCTAssertNil(cache.fresh("price.a", ttl: 10) as Double?, "past its time")
        cache.keep(2.5, for: "price.a", readSince: since)
        XCTAssertEqual(cache.fresh("price.a", ttl: 10) as Double?, 2.5)
        cache.invalidate()
        XCTAssertNil(cache.fresh("price.a", ttl: 10) as Double?, "forgotten")
        cache.keep(3.5, for: "price.a", readSince: since)
        XCTAssertNil(cache.fresh("price.a", ttl: 10) as Double?, "read before the invalidation: never kept")
        cache.keep(4.5, for: "price.a", readSince: cache.generation)
        XCTAssertEqual(cache.fresh("price.a", ttl: 10) as Double?, 4.5)
    }

    // MARK: Kept on the device

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "chain-store-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheStoreKeepsFilesUntilAnErase() throws {
        let folder = try directory()
        let store = ChainStore(directory: folder)
        XCTAssertNil(store.load([String].self, from: "a.json"))
        store.save(["one"], to: "a.json", epoch: store.epoch)
        XCTAssertEqual(store.load([String].self, from: "a.json"), ["one"])
        XCTAssertEqual(ChainStore(directory: folder).load([String].self, from: "a.json"), ["one"], "between launches")
        let values = try folder.appending(path: "a.json").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)

        let readBefore = store.epoch
        store.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        store.save(["two"], to: "a.json", epoch: readBefore)
        XCTAssertNil(store.load([String].self, from: "a.json"), "what was read before the erase is never written after it")
        store.save(["three"], to: "a.json", epoch: store.epoch)
        XCTAssertEqual(store.load([String].self, from: "a.json"), ["three"])
    }

    func testAStoreWithoutAFolderKeepsNothing() {
        let store = ChainStore(directory: nil)
        store.save(["one"], to: "a.json", epoch: store.epoch)
        XCTAssertNil(store.load([String].self, from: "a.json"))
        store.erase()
        XCTAssertEqual(store.epoch, 1)
    }

    func testOnlyWhatSettledIsKept() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ChainSettled.isSettled(1_800_000_000 - 600, now: now))
        XCTAssertFalse(ChainSettled.isSettled(1_800_000_000 - 599, now: now))
        XCTAssertFalse(ChainSettled.isSettled(0, now: now), "a time that wasn't read")
        XCTAssertFalse(ChainSettled.isSettled(1_800_000_100, now: now))
        // A creator's long text isn't kept: that launch or Moment is read in full every time, and the files stay small.
        XCTAssertTrue(ChainSettled.isKeepable(["Name", "SYM", String(repeating: "a", count: 4_089)]))
        XCTAssertFalse(ChainSettled.isKeepable(["Name", "SYM", String(repeating: "a", count: 4_090)]))
        XCTAssertFalse(ChainSettled.isKeepable([String(repeating: "é", count: 2_049)]), "counted in bytes")
    }
}
