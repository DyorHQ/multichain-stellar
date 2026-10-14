import Foundation
import XCTest
@testable import DyorKit

/// Perpl's funding countdown: the blocks left on a market's schedule at Perpl's own interval from its context
/// (`funding_interval_sec` over `funding_interval_blocks`), never an assumed block time.
final class PerplFundingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PerplMockTransport.reset()
    }

    func testTheFundingCountdownUsesPerplsOwnInterval() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "perpl-context", withExtension: "json", subdirectory: "Fixtures"))
        PerplMockTransport.context = (200, try Data(contentsOf: url))
        let session = PerplMockTransport.session()
        let contexts = try await PerplService(rpc: RPCClient(url: Monad.defaultRPC, session: session), session: session).context()
        let btc = try XCTUnwrap(contexts.first { $0.name == "BTC" })
        XCTAssertEqual(btc.fundingIntervalSeconds, 2_580, "the context's funding_interval_sec")
        XCTAssertEqual(btc.fundingIntervalBlocks, 8_571, "and funding_interval_blocks")
        XCTAssertTrue(contexts.allSatisfy { $0.fundingIntervalSeconds == 2_580 && $0.fundingIntervalBlocks == 8_571 })

        // Half an interval left: half of 2,580 s, where an assumed 0.42 s block made it 1,800 s.
        let start: UInt64 = 103_246_266
        let left = try XCTUnwrap(PerplFunding.secondsToNextSettlement(startBlock: start, head: start + 8_571 * 3 + 4_285, context: btc))
        XCTAssertEqual(left, 4_286 * 2_580 / 8_571.0, accuracy: 1e-9)
        XCTAssertEqual(left, 1_290, accuracy: 1)
        // A context that names no interval gives no countdown, never a guess.
        XCTAssertNil(PerplFunding.secondsToNextSettlement(startBlock: start, head: start + 10, intervalSeconds: 0, intervalBlocks: 0))
        let unnamed = MarketContext(id: 1, name: "BTC", priceDecimals: 1, sizeDecimals: 5, mark: 1, last: 1, prev24h: 1, volume24h: 0, openInterest: 0, fundingRate: 0, isOpen: true)
        XCTAssertNil(PerplFunding.secondsToNextSettlement(startBlock: start, head: start + 10, context: unnamed))
        // Another interval length moves the schedule too.
        XCTAssertEqual(PerplFunding.nextSettlementBlock(startBlock: 100, head: 150, intervalBlocks: 40), 180)
        XCTAssertEqual(PerplFunding.nextSettlementBlock(startBlock: 100, head: 150), 100 + 8_571)
    }
}
