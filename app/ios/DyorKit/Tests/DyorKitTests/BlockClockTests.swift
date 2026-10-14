import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// Two Monad mainnet headers 100,000 blocks apart (read 2026-09-30 from rpc1.monad.xyz) and the pace they give, 0.30212 s
/// a block: what the tests that once pinned 0.4 s now estimate times with.
enum BlockClockFixture {
    static let head = BlockHeader(number: 109_380_000, timestamp: 1_790_788_820)
    static let older = BlockHeader(number: 109_280_000, timestamp: 1_790_758_608)
    static let secondsPerBlock = BlockClock.rate(newer: head, older: older)!
}

/// The block clock: the pace measured from two headers once a session, the block 24 hours back found with one timestamp
/// correction, and the fallback pace when the chain can't be read.
final class BlockClockTests: XCTestCase {
    override func setUp() { VenueChainStub.reset(head: BlockClockFixture.head) }

    func testThePaceIsMeasuredFromTwoHeadersOnceASession() async {
        VenueChainStub.header(BlockClockFixture.older.number, BlockClockFixture.older.timestamp)
        let clock = BlockClock(rpc: VenueChainStub.rpc())
        let measured = await clock.secondsPerBlock()
        XCTAssertEqual(measured, 0.30212, accuracy: 1e-9, "30,212 s over 100,000 blocks")
        XCTAssertEqual(measured, BlockClockFixture.secondsPerBlock)
        let isMeasured = await clock.isMeasured
        XCTAssertTrue(isMeasured)
        XCTAssertEqual(VenueChainStub.snapshot.headersAsked, [BlockClockFixture.head.number, BlockClockFixture.older.number])

        // Kept for the session: no header is read again.
        let again = await clock.secondsPerBlock()
        XCTAssertEqual(again, measured)
        XCTAssertEqual(VenueChainStub.snapshot.headersAsked.count, 2)

        // 24 hours is about 285,800 blocks at Monad's pace, never the 216,000 of a 0.4 s block.
        let day = await clock.blocks(in: 86_400)
        XCTAssertEqual(day, 285_980)
        XCTAssertEqual(BlockClock.blocks(in: 86_400, secondsPerBlock: BlockClock.fallbackSecondsPerBlock), 285_809)
        XCTAssertEqual(BlockClock.blocks(in: 0, secondsPerBlock: 0.3), 0)
    }

    /// The block 24 hours before QT's recorded head: counting back at the measured pace lands on 109,094,021, whose own
    /// timestamp is 25 s early, so the estimate moves once, 83 blocks, to 109,094,104 — mined one second after the target.
    func testTheDayAgoBlockIsCorrectedOnceByItsOwnTimestamp() async throws {
        VenueChainStub.header(BlockClockFixture.older.number, BlockClockFixture.older.timestamp)
        VenueChainStub.header(109_094_021, 1_790_702_395)
        let clock = BlockClock(rpc: VenueChainStub.rpc())
        let target = Date(timeIntervalSince1970: TimeInterval(BlockClockFixture.head.timestamp - 86_400))
        let block = try await clock.block(at: target)
        XCTAssertEqual(block, 109_094_104)
        XCTAssertEqual(VenueChainStub.snapshot.headersAsked.last, 109_094_021, "the estimate's own header, read once")

        // The pure steps.
        let estimate = BlockClock.estimate(target: target.timeIntervalSince1970, anchor: BlockClockFixture.head, secondsPerBlock: BlockClockFixture.secondsPerBlock)
        XCTAssertEqual(estimate, 109_094_021)
        XCTAssertEqual(BlockClock.corrected(header: BlockHeader(number: estimate, timestamp: 1_790_702_395), target: target.timeIntervalSince1970,
                                            secondsPerBlock: BlockClockFixture.secondsPerBlock, head: BlockClockFixture.head.number), 109_094_104)
        XCTAssertEqual(BlockClock.corrected(header: BlockHeader(number: 10, timestamp: 1_000), target: 0, secondsPerBlock: 0.3, head: 100), 0, "never before block 0")
        XCTAssertEqual(BlockClock.corrected(header: BlockHeader(number: 90, timestamp: 1_000), target: 2_000, secondsPerBlock: 0.3, head: 100), 100, "never after the head")
        // A time at or after the head is the head.
        let now = try await clock.block(at: Date(timeIntervalSince1970: TimeInterval(BlockClockFixture.head.timestamp + 5)))
        XCTAssertEqual(now, BlockClockFixture.head.number)

        // When the estimate's header can't be read, the first estimate stands.
        VenueChainStub.update { $0.headers[109_094_021] = nil }
        let uncorrected = try await clock.block(at: target)
        XCTAssertEqual(uncorrected, 109_094_021)
    }

    func testAFailedMeasurementFallsBackAndTriesAgainLater() async throws {
        VenueChainStub.update { $0.failHeaders = true }
        let clock = StubClock()
        let blockClock = BlockClock(rpc: VenueChainStub.rpc(), now: { clock.now })
        let fallback = await blockClock.secondsPerBlock()
        XCTAssertEqual(fallback, BlockClock.fallbackSecondsPerBlock)
        XCTAssertEqual(fallback, 0.3023)
        let isMeasured = await blockClock.isMeasured
        XCTAssertFalse(isMeasured)

        // The chain answers again: within a minute the fallback stands, unread; after it, the pace is measured.
        VenueChainStub.update { $0.failHeaders = false }
        VenueChainStub.header(BlockClockFixture.older.number, BlockClockFixture.older.timestamp)
        let asked = VenueChainStub.snapshot.headersAsked.count
        let soon = await blockClock.secondsPerBlock()
        XCTAssertEqual(soon, BlockClock.fallbackSecondsPerBlock)
        XCTAssertEqual(VenueChainStub.snapshot.headersAsked.count, asked, "no read before the retry")
        clock.now = clock.now.addingTimeInterval(BlockClock.retryAfter + 1)
        let later = await blockClock.secondsPerBlock()
        XCTAssertEqual(later, BlockClockFixture.secondsPerBlock, accuracy: 1e-12)

        // Headers that don't make a pace (the same block, time running backwards, a pace no chain has) are a failure.
        XCTAssertNil(BlockClock.rate(newer: BlockClockFixture.head, older: BlockClockFixture.head))
        XCTAssertNil(BlockClock.rate(newer: BlockHeader(number: 10, timestamp: 5), older: BlockHeader(number: 5, timestamp: 9)))
        XCTAssertNil(BlockClock.rate(newer: BlockHeader(number: 100_000, timestamp: 1_000_000), older: BlockHeader(number: 0, timestamp: 0)), "10 s a block")
    }

    func testTimesAreEstimatedAtTheGivenPace() {
        let anchor = BlockHeader(number: 1_000, timestamp: 1_800_000_000)
        XCTAssertEqual(BlockClock.time(of: 900, anchor: anchor, secondsPerBlock: 0.3).timeIntervalSince1970, 1_800_000_000 - 30, accuracy: 1e-6)
        XCTAssertEqual(BlockClock.time(of: 1_200, anchor: anchor, secondsPerBlock: 0.3).timeIntervalSince1970, 1_800_000_000, "a later block takes the anchor's time")
        XCTAssertEqual(LaunchpadService.time(anchor: anchor, block: 990, secondsPerBlock: BlockClockFixture.secondsPerBlock), 1_799_999_997, "3.02 s earlier, rounded")
        XCTAssertEqual(MomentsService.time(anchor: anchor, block: 0, secondsPerBlock: 0.5).timeIntervalSince1970, 1_800_000_000 - 500, accuracy: 1e-6)
    }

    /// A Moment's holder scan reaches back past its publish at the session's pace, with its margins (a quarter more and
    /// 2,000 blocks): at 0.4 s it fell about 6% short of a 0.3 s chain's blocks before the margin.
    func testTheMomentsHistoryLookbackCoversTheMomentsAge() {
        for age in [0, 3_600, 86_400, 10 * 86_400, 40 * 86_400] {
            let lookback = MomentsService.holderLookback(ageSeconds: age, secondsPerBlock: BlockClockFixture.secondsPerBlock)
            let blocksSincePublish = BlockClock.blocks(in: TimeInterval(age), secondsPerBlock: BlockClockFixture.secondsPerBlock)
            XCTAssertGreaterThanOrEqual(lookback, blocksSincePublish + 2_000, "age \(age) s")
            XCTAssertEqual(lookback, BlockClock.blocks(in: TimeInterval(age) * 1.25, secondsPerBlock: BlockClockFixture.secondsPerBlock) + 2_000)
        }
        // Even on a chain 10% faster than measured, a ten-day-old Moment's publish is inside the scan.
        let tenDays = MomentsService.holderLookback(ageSeconds: 10 * 86_400, secondsPerBlock: BlockClockFixture.secondsPerBlock)
        XCTAssertGreaterThan(tenDays, BlockClock.blocks(in: 10 * 86_400, secondsPerBlock: BlockClockFixture.secondsPerBlock * 0.9))
        XCTAssertEqual(MomentsService.holderLookback(ageSeconds: -50, secondsPerBlock: 0.3), 2_000, "a clock ahead of the chain reads the margin")
    }

    /// Scan windows that are block budgets keep their counts, and say blocks; the history filters a user picks are their
    /// true length at the measured pace.
    func testScanBudgetsKeepTheirBlocksAndFiltersAreTrueTimes() {
        XCTAssertEqual(WalletTokenDiscovery.defaultWindowBlocks, 6_480_000)
        XCTAssertEqual(TokenActivityService.defaultLookbackBlocks, 54_000)
        XCTAssertEqual(SwapHistoryService.Window.allBlocks, 19_440_000)
        XCTAssertEqual(SwapHistoryService.Window.all.blocks(secondsPerBlock: 0.3), 19_440_000, "All is a budget")
        XCTAssertEqual(SwapHistoryService.Window.day.blocks(secondsPerBlock: 0.3), 288_000)
        XCTAssertEqual(SwapHistoryService.Window.week.blocks(secondsPerBlock: 0.3), 2_016_000)
        XCTAssertEqual(SwapHistoryService.Window.month.blocks(secondsPerBlock: 0.3), 8_640_000)
        XCTAssertEqual(SwapHistoryService.Window.day.blocks, 285_809, "without a clock, the fallback pace")
    }
}
