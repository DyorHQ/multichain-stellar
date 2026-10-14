import XCTest
@testable import DyorKit

/// The market-data feed across reconnects: every (re)subscribe resends the trades snapshot, which must replace the
/// tape rather than double it, and each socket numbers its heartbeats from scratch.
@MainActor
final class PerplFeedTests: XCTestCase {
    private func btc() -> PerpMarket {
        PerpMarket(id: 1, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0,
                   mark: 95000, last: 95000, oracle: 95000, markTimestamp: 0, longOI: 0, shortOI: 0,
                   fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
    }

    private func frame(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testTradeTapeIsReplacedBySnapshotNotDoubled() {
        let feed = PerplFeed(wsURL: URL(string: "ws://127.0.0.1:9/")!)
        feed.focus(btc())
        feed.stop()
        let snapshot = frame(["mt": 17, "d": [["p": 950010, "s": 1000, "sd": 1, "at": ["t": 2000]], ["p": 950000, "s": 500, "sd": 2, "at": ["t": 1000]]]])
        feed.handle(snapshot)
        XCTAssertEqual(feed.trades.map(\.price), [95001, 95000])
        // A reconnect resends the snapshot: the tape is replaced, not doubled.
        feed.handle(snapshot)
        XCTAssertEqual(feed.trades.map(\.price), [95001, 95000])
        // Updates go on top.
        feed.handle(frame(["mt": 18, "d": [["p": 950020, "s": 100, "sd": 1, "at": ["t": 3000]]]]))
        XCTAssertEqual(feed.trades.map(\.price), [95002, 95001, 95000])

        feed.handle(frame(["mt": 100, "sn": 41]))
        XCTAssertEqual(feed.lastHeartbeat, 41)
        // A new socket numbers its heartbeats from scratch.
        feed.focus(PerpMarket(id: 20, symbol: "ETH", name: "Ether", priceDecimals: 2, lotDecimals: 4, basePricePNS: 0,
                              mark: 3000, last: 3000, oracle: 3000, markTimestamp: 0, longOI: 0, shortOI: 0,
                              fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0))
        feed.stop()
        XCTAssertNil(feed.lastHeartbeat)
    }
}
