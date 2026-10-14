import Foundation
import XCTest
@testable import DyorKit

/// The shared head (`HeadClock`): read once for every reader that asks within its age, shared while it is read, a failure
/// never kept, a reader that must see every block mined before it asked always reading anew, a `forget()` taking effect at
/// once; and the readers that take it — the block clock, prices and the wallet's history rounds.
final class HeadClockTests: XCTestCase {
    /// A device clock a test moves.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    /// A chain head read from memory: each read counted, answered after `delay`, failing while `failing`.
    private final class Chain: @unchecked Sendable {
        private let lock = NSLock()
        private var number: UInt64 = 100
        private var count = 0
        var delay: Duration = .zero
        var failing = false
        var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
        func mine() { lock.lock(); number += 1; lock.unlock() }
        func read() async throws -> BlockHeader {
            lock.lock(); count += 1; let failing = failing, delay = delay; lock.unlock()
            if delay > .zero { try? await Task.sleep(for: delay) }
            if failing { throw URLError(.timedOut) }
            lock.lock(); defer { lock.unlock() }
            return BlockHeader(number: number, timestamp: 1_800_000_000 + Int(number))
        }
    }

    func testReadersWithinItsAgeShareOneRead() async throws {
        let time = TestClock(), chain = Chain()
        chain.delay = .milliseconds(100)
        let head = HeadClock(now: { time.now }, read: { try await chain.read() })
        // Five readers at once: one read.
        let numbers = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for _ in 0..<5 { group.addTask { try await head.number() } }
            return try await group.reduce(into: [UInt64]()) { $0.append($1) }
        }
        XCTAssertEqual(numbers, Array(repeating: 100, count: 5))
        XCTAssertEqual(chain.reads, 1)
        let known = await head.known
        XCTAssertEqual(known?.number, 100)

        // Within its age: no read. After it: read again.
        chain.mine()
        time.advance(0.5)
        let kept = try await head.number()
        XCTAssertEqual(kept, 100)
        XCTAssertEqual(chain.reads, 1)
        time.advance(0.6)
        let fresh = try await head.number()
        XCTAssertEqual(fresh, 101)
        XCTAssertEqual(chain.reads, 2)
        XCTAssertEqual(HeadClock.maxAge, 1)
    }

    /// A reader asking with no age (a history round after a transaction settled) always reads anew: never a head read
    /// before it asked, nor one under way since before; and its head serves the readers after it.
    func testAReaderThatMustSeeEveryBlockReadsAnew() async throws {
        let time = TestClock(), chain = Chain()
        let head = HeadClock(now: { time.now }, read: { try await chain.read() })
        _ = try await head.latest()
        chain.mine()
        let anew = try await head.latest(maxAge: 0)
        XCTAssertEqual(anew.number, 101)
        XCTAssertEqual(chain.reads, 2)
        let shared = try await head.latest()
        XCTAssertEqual(shared.number, 101, "kept for the readers after it")
        XCTAssertEqual(chain.reads, 2)

        // A read under way since before it asked is not joined.
        chain.delay = .milliseconds(200)
        time.advance(5)
        async let slow = head.latest()
        // The slow read has begun (its third read counted) before the reader that must see every block asks.
        try await waitUntil { chain.reads == 3 }
        time.advance(0.01)
        chain.mine()
        let own = try await head.latest(maxAge: 0)
        let earlier = try await slow
        XCTAssertEqual(chain.reads, 4, "its own read")
        XCTAssertEqual(own.number, 102)
        XCTAssertLessThanOrEqual(earlier.number, own.number)
        let kept = await head.known
        XCTAssertEqual(kept?.number, 102, "the read begun last is kept")
    }

    /// A `forget()` (`AppEnvironment.invalidateChainReads`) takes effect at once: the head kept is not taken after it,
    /// however young; a read under way since before it is not joined; and what such a read brings back is not kept.
    func testForgettingReadsTheHeadAnew() async throws {
        let time = TestClock(), chain = Chain()
        let head = HeadClock(now: { time.now }, read: { try await chain.read() })
        _ = try await head.latest()
        chain.mine()
        head.forget()
        let known = await head.known
        XCTAssertNil(known, "nothing kept from before")
        let anew = try await head.latest()
        XCTAssertEqual(anew.number, 101, "read anew, though the last is no older than its second")
        XCTAssertEqual(chain.reads, 2)
        let shared = try await head.latest()
        XCTAssertEqual(shared.number, 101, "and kept for the readers after it")
        XCTAssertEqual(chain.reads, 2)

        // A read under way when it is forgotten: still answers those waiting for it, joined by no one after, never kept.
        chain.delay = .milliseconds(200)
        time.advance(5)
        async let before = head.latest()
        try await waitUntil { chain.reads == 3 }
        head.forget()
        chain.mine()
        let after = try await head.latest()
        let earlier = try await before
        XCTAssertEqual(chain.reads, 4, "the read after it is its own")
        XCTAssertEqual(after.number, 102)
        XCTAssertLessThanOrEqual(earlier.number, after.number)
        let kept = await head.known
        XCTAssertEqual(kept?.number, 102, "only the read begun after it is kept")
    }

    /// A failed read is shared with the readers waiting for it and never kept: the next reader reads again.
    func testAFailureIsNeverKept() async throws {
        let time = TestClock(), chain = Chain()
        chain.failing = true
        chain.delay = .milliseconds(50)
        let head = HeadClock(now: { time.now }, read: { try await chain.read() })
        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 { group.addTask { (try? await head.latest()) == nil } }
            return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        }
        XCTAssertEqual(failures, 3)
        XCTAssertEqual(chain.reads, 1, "the readers shared the read")
        let known = await head.known
        XCTAssertNil(known)
        chain.failing = false
        let read = try await head.number()
        XCTAssertEqual(read, 100)
        XCTAssertEqual(chain.reads, 2)
    }

    /// A reader that leaves (a screen closed) doesn't cancel the read for the others waiting for it.
    func testAReaderThatLeavesDoesNotCancelTheRead() async throws {
        let chain = Chain()
        chain.delay = .milliseconds(200)
        let head = HeadClock(read: { try await chain.read() })
        let leaving = Task { try await head.latest() }
        try await Task.sleep(for: .milliseconds(50))
        async let staying = head.latest()
        leaving.cancel()
        let header = try await staying
        XCTAssertEqual(header.number, 100)
        XCTAssertEqual(chain.reads, 1)
    }

    /// A clock set back never makes a head seem younger than it is.
    func testAHeadFromTheFutureIsNotFresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(HeadClock.isWithin(now - 0.5, of: now, maxAge: 1))
        XCTAssertFalse(HeadClock.isWithin(now - 1, of: now, maxAge: 1))
        XCTAssertFalse(HeadClock.isWithin(now + 0.5, of: now, maxAge: 1))
        XCTAssertFalse(HeadClock.isWithin(now, of: now, maxAge: 0))
    }

    /// The block clock takes its head from its `HeadClock`: a day-ago block and a measurement within a second read it once.
    func testTheBlockClockTakesTheSharedHead() async throws {
        VenueChainStub.reset(head: BlockClockFixture.head)
        VenueChainStub.header(BlockClockFixture.older.number, BlockClockFixture.older.timestamp)
        let rpc = VenueChainStub.rpc()
        // A device clock that stands still: the head ages on test time, so the three readers take one head however long
        // the stubbed round trips take.
        let frozen = Date(timeIntervalSince1970: TimeInterval(BlockClockFixture.head.timestamp))
        let clock = BlockClock(rpc: rpc, now: { frozen })
        _ = try await clock.block(at: Date(timeIntervalSince1970: TimeInterval(BlockClockFixture.head.timestamp - 3_600)))
        _ = await clock.secondsPerBlock()
        _ = try await clock.block(at: Date(timeIntervalSince1970: TimeInterval(BlockClockFixture.head.timestamp - 7_200)))
        let heads = VenueChainStub.snapshot.headersAsked.filter { $0 == BlockClockFixture.head.number }.count
        XCTAssertEqual(heads, 1, "one head read for all three")
        let known = await clock.head.known
        XCTAssertEqual(known, BlockClockFixture.head)

        // A clock given a head clock uses it, and the price service its clock's.
        let given = HeadClock(read: { BlockHeader(number: 5, timestamp: 1) })
        let pinned = BlockClock(rpc: rpc, head: given)
        XCTAssertTrue(pinned.head === given)
        let prices = PriceService(rpc: rpc, clock: pinned)
        let pricesClock = await prices.clock
        XCTAssertTrue(pricesClock.head === given)
    }

    /// The app's one clock, and with it its one head, is the one prices and the wallet's history take; the head a round
    /// reads to is read anew on it, the logs endpoints' own only when it can't be read.
    func testTheAppSharesOneHead() throws {
        let environment = try DocsLinksTests.appSource("App/AppEnvironment.swift")
        XCTAssertEqual(environment.components(separatedBy: "BlockClock(").count - 1, 1, "one clock")
        XCTAssertEqual(environment.components(separatedBy: "HeadClock(").count - 1, 0, "its head, never another")
        XCTAssertTrue(environment.contains("prices = PriceService(rpc: rpc, registry: registry, clock: clock,"))
        XCTAssertTrue(environment.contains("chainCache.invalidate()\n        clock.head.forget()"), "an invalidation forgets the shared head with the shared reads")
        XCTAssertTrue(environment.contains("walletHistory = WalletHistoryService(store: historyStore, swapHistory: swapHistory, clock: clock,"))
        let history = try String(contentsOf: Self.kit("Services/WalletHistory.swift"), encoding: .utf8)
        XCTAssertTrue(history.contains("let latest = await roundHead()"))
        XCTAssertTrue(history.contains("if let head = try? await clock.head.latest(maxAge: 0) { return head }\n        return await store.latest()"))
        let prices = try String(contentsOf: Self.kit("Services/Prices/PriceService.swift"), encoding: .utf8)
        XCTAssertFalse(prices.contains("rpc.block(.latest)"), "every head from the shared one")
        XCTAssertEqual(prices.components(separatedBy: "clock.head.latest()").count - 1, 2, "the day-ago block and a chart")
    }

    /// Waits until `condition` holds, for at most three seconds.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held", file: file, line: line)
    }

    private static func kit(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DyorKit").appendingPathComponent(path)
    }
}
