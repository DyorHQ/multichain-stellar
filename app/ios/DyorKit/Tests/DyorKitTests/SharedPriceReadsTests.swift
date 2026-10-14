import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// Prices every screen shares (`PriceService` with a `ChainCache`): identical reads at once are one read, a token's
/// price is kept `ChainCache.TTL.price` seconds and the day-ago block a minute, so a warm read is one round trip; an
/// invalidation reads again; and the pools found are kept on the device with the time each was found (RS-12), for the
/// venue setting they were found under. Runs `PriceService`'s real code against `VenueChainStub`.
final class SharedPriceReadsTests: XCTestCase {
    static let head = BlockHeader(number: 2_000_000, timestamp: 1_800_000_000)
    static let dayAgo: UInt64 = 2_000_000 - 288_000
    static let monPool = PoolKey.canonical(Monad.native, Monad.usdc, fee: 500, tickSpacing: 10).id

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

    override func setUp() {
        VenueChainStub.reset(head: Self.head)
        VenueChainStub.header(Self.head.number - 100_000, Self.head.timestamp - 30_000)
        VenueChainStub.header(Self.dayAgo, Self.head.timestamp - 86_400)
        VenueChainStub.update { $0.liquidity[Self.monPool] = BigUInt(10).power(20) }
        monPrice(0.03)
        monPrice(0.025, at: Self.dayAgo)
    }

    /// MON at `usd` in the MON/USDC v4 pool (MON is currency0), at `block` or any block.
    private func monPrice(_ usd: Double, at block: UInt64? = nil) {
        let sqrt = BigUInt((usd * 1e6 / 1e18).squareRoot() * pow(2, 96))
        VenueChainStub.answer(Uniswap.stateView, try! SwapCalldata.stateViewSlot0(poolId: Self.monPool), at: block,
                              with: try! ABI.encode([.uint(sqrt), .int(0), .uint(0), .uint(0)], "uint160,int24,uint24,uint24"))
    }

    private var requests: Int { VenueChainStub.snapshot.requests }
    private var headReads: Int { VenueChainStub.snapshot.headersAsked.filter { $0 == Self.head.number }.count }
    private var lookups: Int { VenueChainStub.snapshot.calls.filter { $0.data.prefix(4) == ABI.selector("getLiquidity(bytes32)") }.count }

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "shared-prices-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// `head`: the time the shared head (`HeadClock`) is aged on, when a test moves it; nil, the device's.
    private func service(cache: ChainCache? = ChainCache(), store: ChainStore? = nil, venues: Bool = true, clock: Clock = Clock(), head: Clock? = nil) -> PriceService {
        let rpc = VenueChainStub.rpc()
        let blockClock = head.map { head in BlockClock(rpc: rpc, head: HeadClock(rpc: rpc, now: { head.now })) }
        return PriceService(rpc: rpc, clock: blockClock, dyorVenues: venues, now: { clock.now }, cache: cache, store: store)
    }

    /// Two screens reading the same prices at once (Home and the Portfolio at launch) cost what one read costs.
    func testIdenticalReadsAtOnceAreOneRead() async throws {
        let alone = service(cache: nil)
        let before = requests
        let one = try await alone.prices(for: [.mon])
        let single = requests - before
        XCTAssertEqual(try XCTUnwrap(one[Monad.native]).usd, 0.03, accuracy: 1e-9)

        let shared = service()
        let start = requests
        async let a = shared.prices(for: [.mon])
        async let b = shared.prices(for: [.mon])
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(requests - start, single, "one read for both")
    }

    /// Two screens pricing different lists at once look a token's pools up once: the second discovery waits for the first.
    func testTwoReadsAtOnceLookATokenUpOnce() async throws {
        let prices = service(cache: nil)
        async let a = prices.prices(for: [.mon])
        async let b = prices.prices(for: [.mon, .usdc])
        _ = try await (a, b)
        XCTAssertEqual(lookups, Uniswap.v4Tiers.count, "MON's v4 pools looked up once")
    }

    /// A read whose tokens were all looked up lately waits for no lookup under way of other tokens, however slow: only a
    /// read due a token being looked up waits for that lookup. (The first speed pass queued every price read behind any
    /// discovery under way, its RPC timeouts included.)
    func testAReadWaitsOnlyForTheLookupsOfItsOwnTokens() async throws {
        let prices = service(cache: nil)
        _ = try await prices.prices(for: [.mon])
        let other = Token(address: Address(literal: "0x00000000000000000000000000000000000e1e01"), symbol: "OTHER", name: "Other", decimals: 18)
        let held = VenueChainStub.hold(ABI.selector("getPool(address,address,uint24)"))
        let slow = Task { try await prices.prices(for: [other]) }
        try await held.arrival()
        let started = ContinuousClock.now
        let mon = try await prices.prices(for: [.mon])
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "never behind the held lookup")
        XCTAssertEqual(try XCTUnwrap(mon[Monad.native]).usd, 0.03, accuracy: 1e-9)
        held.release.signal()
        _ = try await slow.value
    }

    /// A price is kept for its time, and the day-ago block for a minute: within it a read costs nothing; after it, only the
    /// prices are read (no head, no day-ago lookup); an invalidation, which forgets the shared head with the shared reads
    /// (`AppEnvironment.invalidateChainReads`, `HeadClock.forget`), reads the head again, however recent the last.
    func testAPriceIsKeptForItsTimeAndAWarmReadIsOneRoundTrip() async throws {
        let clock = Clock()
        let cache = ChainCache(now: { clock.now })
        let prices = service(cache: cache, head: clock)
        let first = try await prices.prices(for: [.mon])
        XCTAssertEqual(try XCTUnwrap(first[Monad.native]).change24h ?? 0, 20, accuracy: 1e-6)

        var start = requests
        let kept = try await prices.prices(for: [.mon])
        XCTAssertEqual(requests, start, "kept within its time")
        XCTAssertEqual(kept, first)

        clock.advance(ChainCache.TTL.price)
        start = requests
        let heads = headReads
        let warm = try await prices.prices(for: [.mon])
        XCTAssertEqual(try XCTUnwrap(warm[Monad.native]).usd, 0.03, accuracy: 1e-9)
        XCTAssertEqual(headReads, heads, "the day-ago block is kept a minute")
        XCTAssertEqual(requests - start, 2, "the prices now and a day ago, side by side")
        XCTAssertEqual(lookups, Uniswap.v4Tiers.count, "the pool found is kept")

        let head = await prices.clock.head
        cache.invalidate()
        head.forget()
        _ = try await prices.prices(for: [.mon])
        XCTAssertEqual(headReads, heads + 1, "read again after an invalidation")

        // Invalidated again within the head's second (a transaction settled just after a pull to refresh): the head read
        // under a second ago is forgotten too, and read anew, as the invalidation promises of every read begun before it.
        cache.invalidate()
        head.forget()
        let before = requests
        _ = try await prices.prices(for: [.mon])
        XCTAssertEqual(headReads, heads + 2, "the head is read anew, however recent the last")
        XCTAssertGreaterThan(requests, before, "the prices and the day-ago block read again")
    }

    /// The pools found are kept on the device with when each was found: a relaunch prices with no lookup, a lookup past its
    /// time is made again, a file of the other venue setting is never used, and an erase removes them.
    func testThePoolsFoundAreKeptOnTheDeviceWithTheirTime() async throws {
        let folder = folder()
        _ = try await service(store: ChainStore(directory: folder)).prices(for: [.mon])
        XCTAssertEqual(lookups, Uniswap.v4Tiers.count)

        let relaunched = service(store: ChainStore(directory: folder))
        let read = try await relaunched.prices(for: [.mon])
        XCTAssertEqual(try XCTUnwrap(read[Monad.native]).usd, 0.03, accuracy: 1e-9)
        XCTAssertEqual(lookups, Uniswap.v4Tiers.count, "no lookup after a relaunch")

        let later = Clock()
        later.advance(31 * 60)
        _ = try await service(store: ChainStore(directory: folder), clock: later).prices(for: [.mon])
        XCTAssertEqual(lookups, 2 * Uniswap.v4Tiers.count, "a pool found more than 30 minutes ago is looked up again")
        _ = try await service(store: ChainStore(directory: folder), clock: later).prices(for: [.mon])
        XCTAssertEqual(lookups, 2 * Uniswap.v4Tiers.count, "and kept from then")

        _ = try await service(store: ChainStore(directory: folder), venues: false, clock: later).prices(for: [.mon])
        XCTAssertEqual(lookups, 3 * Uniswap.v4Tiers.count, "the other venue setting's pools are never used")
        _ = try await service(store: ChainStore(directory: folder), clock: later).prices(for: [.mon])
        XCTAssertEqual(lookups, 4 * Uniswap.v4Tiers.count, "nor the other way round")

        let store = ChainStore(directory: folder)
        let erased = service(store: store, clock: later)
        store.erase()
        _ = try await erased.prices(for: [.mon])
        XCTAssertEqual(lookups, 5 * Uniswap.v4Tiers.count, "an erase removes the pools kept")
        XCTAssertNotNil(store.load(PriceService.SavedPools.self, from: PriceService.poolsFile), "and what is found after it is kept")
    }

    /// A pool kept with a time after now (the clock was set back) is looked up again at once.
    func testALookupDatedInTheFutureIsDue() {
        var cache = PoolLookupCache<Int>()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        cache.restore(hits: [(Monad.native, 1, now.addingTimeInterval(600), true)], misses: [(Monad.wmon, now.addingTimeInterval(60))])
        XCTAssertTrue(cache.needsLookup(Monad.native, now: now))
        XCTAssertTrue(cache.needsLookup(Monad.wmon, now: now))
        XCTAssertEqual(cache.source(Monad.native), 1, "and still prices until a lookup says otherwise")
        cache.found(Monad.native, 2, now: now)
        cache.restore(hits: [(Monad.native, 3, now, true)], misses: [])
        XCTAssertEqual(cache.source(Monad.native), 2, "what this session found wins over what was kept")
        XCTAssertFalse(cache.needsLookup(Monad.native, now: now.addingTimeInterval(60)))
    }

    /// The venue switch drops what was priced the other way: a read after it never takes a price kept before it.
    func testTheVenueSwitchDropsThePricesKept() async throws {
        let prices = service()
        _ = try await prices.prices(for: [.mon])
        await prices.setUsesDyorVenues(false)
        let start = requests
        _ = try await prices.prices(for: [.mon])
        XCTAssertGreaterThan(requests, start, "read again under the new setting")
    }
}
