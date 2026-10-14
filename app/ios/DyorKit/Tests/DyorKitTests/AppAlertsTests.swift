import XCTest
@testable import DyorKit

/// Alerts while the app is open (build 17, N2): Perps margin usage and its warnings with hysteresis, the
/// near-liquidation rule, fills and endings (one notice with the trading stream's), the switches, price alerts and the
/// one watcher loop. The app's wiring of them is `AppAlertsWiringTests`.
final class AppAlertsTests: XCTestCase {
    private let a = Address(literal: "0x1111111111111111111111111111111111111111")
    private let b = Address(literal: "0x2222222222222222222222222222222222222222")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A position as `PerplService.positions` builds it: unrealized profit and the liquidation price from the same inputs.
    private func position(_ perpId: Int, _ side: PositionSide, size: Double, entry: Double, mark: Double, margin: Double,
                          premium: Double = 0, maintenance: Double? = 0.05) -> PerpPosition {
        let unrealized = (side == .long ? mark - entry : entry - mark) * size + premium
        return PerpPosition(perpId: perpId, symbol: "BTC", side: side, size: size, entry: entry, mark: mark, margin: margin,
                            unrealized: unrealized, premium: premium, leverage: margin > 0 ? size * mark / margin : 0,
                            liquidation: PerplService.liquidationPrice(side: side, entry: entry, size: size, margin: margin, premium: premium,
                                                                      maintenanceFraction: maintenance),
                            notional: size * mark)
    }

    // MARK: - Margin usage

    /// Margin usage = maintenance margin needed (entry × size × maintenance fraction) / equity (margin + P&L at the mark +
    /// premium), worked by hand for a long and a short, with and without a premium.
    func testMarginUsageFixtures() throws {
        // Long, no premium: needed 100 × 2 × 5% = 10; equity 20 + (98 − 100) × 2 = 16.
        XCTAssertEqual(try XCTUnwrap(PerpRisk.marginUsage(side: .long, entry: 100, size: 2, mark: 98, margin: 20, premium: 0, maintenanceFraction: 0.05)), 0.625, accuracy: 1e-12)
        // Short, no premium: needed 10; equity 20 + (100 − 104) × 2 = 12.
        XCTAssertEqual(try XCTUnwrap(PerpRisk.marginUsage(side: .short, entry: 100, size: 2, mark: 104, margin: 20, premium: 0, maintenanceFraction: 0.05)), 10.0 / 12, accuracy: 1e-12)
        // Long, a funding premium owed: needed 2000 × 0.5 × 2.5% = 25; equity 100 + (1900 − 2000) × 0.5 − 5 = 45.
        XCTAssertEqual(try XCTUnwrap(PerpRisk.marginUsage(side: .long, entry: 2000, size: 0.5, mark: 1900, margin: 100, premium: -5, maintenanceFraction: 0.025)), 25.0 / 45, accuracy: 1e-12)
        // Short, a premium earned: needed 50 × 10 × 5% = 25; equity 60 + (50 − 51) × 10 + 2 = 52.
        XCTAssertEqual(try XCTUnwrap(PerpRisk.marginUsage(side: .short, entry: 50, size: 10, mark: 51, margin: 60, premium: 2, maintenanceFraction: 0.05)), 25.0 / 52, accuracy: 1e-12)
        // A 10% maintenance market (LIT, VVV, TAO, PUMP) needs twice as much.
        XCTAssertEqual(try XCTUnwrap(PerpRisk.marginUsage(side: .long, entry: 100, size: 2, mark: 98, margin: 20, premium: 0, maintenanceFraction: 0.10)), 1.25, accuracy: 1e-12)

        // The same as the position read gives it (margin + unrealized).
        let read = position(1, .long, size: 0.5, entry: 2000, mark: 1900, margin: 100, premium: -5, maintenance: 0.025)
        XCTAssertEqual(try XCTUnwrap(PerpRisk.marginUsage(read, maintenanceFraction: 0.025)), 25.0 / 45, accuracy: 1e-12)

        // Equity gone: past liquidation, never a negative or a division by zero.
        XCTAssertEqual(PerpRisk.marginUsage(side: .long, entry: 100, size: 1, mark: 50, margin: 10, premium: 0, maintenanceFraction: 0.05), .infinity)
        XCTAssertEqual(PerpRisk.marginUsage(side: .short, entry: 100, size: 1, mark: 110, margin: 10, premium: 0, maintenanceFraction: 0.05), .infinity)
        // A rounding residue where margin, P&L and premium cancel out is no equity: past liquidation, not 5e15 (500 trillion %).
        XCTAssertEqual(PerpRisk.marginUsage(side: .long, entry: 100, size: 1, mark: 100, margin: 1e-15, premium: 0, maintenanceFraction: 0.05), .infinity)
        XCTAssertEqual(PerpRisk.marginUsage(side: .short, entry: 100, size: 1, mark: 100, margin: 0.0000009, premium: 0, maintenanceFraction: 0.05), .infinity)
        XCTAssertEqual(try XCTUnwrap(PerpRisk.marginUsage(side: .long, entry: 100, size: 1, mark: 100, margin: PerpRisk.equityFloor, premium: 0, maintenanceFraction: 0.05)), 5e6, accuracy: 1e-3,
                       "one AUSD unit is still equity")
        // Unknown, never guessed: no maintenance fraction, or nothing to value.
        XCTAssertNil(PerpRisk.marginUsage(side: .long, entry: 100, size: 1, mark: 99, margin: 10, premium: 0, maintenanceFraction: nil))
        XCTAssertNil(PerpRisk.marginUsage(side: .long, entry: 100, size: 1, mark: 99, margin: 10, premium: 0, maintenanceFraction: 0))
        XCTAssertNil(PerpRisk.marginUsage(side: .long, entry: 100, size: 0, mark: 99, margin: 10, premium: 0, maintenanceFraction: 0.05))
        XCTAssertNil(PerpRisk.marginUsage(side: .long, entry: 100, size: 1, mark: 0, margin: 10, premium: 0, maintenanceFraction: 0.05))
        XCTAssertNil(PerpRisk.marginUsage(side: .long, entry: 100, size: 1, mark: .nan, margin: 10, premium: 0, maintenanceFraction: 0.05))
    }

    /// Usage is 100% exactly when the mark is at the liquidation price `PerplService.liquidationPrice` gives, for both sides,
    /// with and without a premium, on 5% and 10% markets: the warnings and the liquidation price can't disagree.
    func testUsageIsOneAtTheLiquidationPrice() throws {
        for side in [PositionSide.long, .short] {
            for maintenance in [0.05, 0.10, 0.025] {
                for premium in [0.0, -3.5, 2.25] {
                    for (entry, size, margin) in [(100.0, 2.0, 40.0), (97_000.0, 0.013, 180.0), (0.042, 25_000.0, 400.0)] {
                        let liquidation = try XCTUnwrap(PerplService.liquidationPrice(side: side, entry: entry, size: size, margin: margin, premium: premium, maintenanceFraction: maintenance))
                        guard liquidation > 0 else { continue }
                        let usage = try XCTUnwrap(PerpRisk.marginUsage(side: side, entry: entry, size: size, mark: liquidation, margin: margin, premium: premium, maintenanceFraction: maintenance))
                        XCTAssertEqual(usage, 1, accuracy: 1e-9, "\(side) \(maintenance) \(premium) \(entry)")
                        XCTAssertEqual(try XCTUnwrap(PerpRisk.liquidationDistance(side: side, mark: liquidation, liquidation: liquidation)), 0, accuracy: 1e-12)
                    }
                }
            }
        }
    }

    /// The distance to liquidation, as a fraction of the mark, and 0 once the mark has reached or passed it.
    func testLiquidationDistance() throws {
        XCTAssertEqual(try XCTUnwrap(PerpRisk.liquidationDistance(side: .long, mark: 100, liquidation: 92)), 0.08, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(PerpRisk.liquidationDistance(side: .short, mark: 100, liquidation: 109)), 0.09, accuracy: 1e-12)
        XCTAssertEqual(PerpRisk.liquidationDistance(side: .long, mark: 90, liquidation: 92), 0, "passed")
        XCTAssertEqual(PerpRisk.liquidationDistance(side: .short, mark: 110, liquidation: 109), 0, "passed")
        XCTAssertEqual(PerpRisk.liquidationDistance(side: .long, mark: 100, liquidation: 0), 1, "a long that can't be liquidated")
        XCTAssertNil(PerpRisk.liquidationDistance(side: .long, mark: 100, liquidation: nil), "unknown maintenance")
        XCTAssertNil(PerpRisk.liquidationDistance(side: .long, mark: 0, liquidation: 92))
    }

    // MARK: - Thresholds and hysteresis

    /// Steps `readings` (usage, distance) from `start` and returns the notices.
    private func walk(_ readings: [(Double?, Double?)], from start: PerpRiskLevel = .normal) -> [PerpRiskLevel?] {
        var level = start
        return readings.map { usage, distance in
            let step = PerpRiskLevel.next(from: level, usage: usage, distance: distance)
            level = step.level
            return step.notify
        }
    }

    /// 80% warns once; a position hovering at 80% doesn't warn again until it has dropped below 75%. 90% is critical once;
    /// it re-arms below 85%, falling back to a warning without a notice.
    func testThresholdsAndHysteresis() {
        XCTAssertEqual(walk([(0.79, 0.5), (0.80, 0.5), (0.78, 0.5), (0.80, 0.5), (0.81, 0.5), (0.76, 0.5), (0.80, 0.5), (0.74, 0.5), (0.80, 0.5)]),
                       [nil, .warning, nil, nil, nil, nil, nil, nil, .warning])
        XCTAssertEqual(walk([(0.85, 0.5), (0.90, 0.5), (0.86, 0.5), (0.91, 0.5), (0.84, 0.5), (0.89, 0.5), (0.90, 0.5)]),
                       [.warning, .critical, nil, nil, nil, nil, .critical])
        // Straight to critical: one notice, the critical one.
        XCTAssertEqual(walk([(0.5, 0.5), (0.95, 0.5), (0.97, 0.5), (.infinity, 0)]), [nil, .critical, nil, nil])
        // Down from critical through every re-arm point, then up again: each level notifies again.
        XCTAssertEqual(walk([(0.92, 0.5), (0.70, 0.5), (0.80, 0.5), (0.90, 0.5)]), [.critical, nil, .warning, .critical])
        // Exactly at a threshold counts; exactly at a re-arm point holds.
        var step = PerpRiskLevel.next(from: .normal, usage: PerpRiskLevel.warningAt, distance: nil)
        XCTAssertEqual(step.level, .warning); XCTAssertEqual(step.notify, .warning)
        step = PerpRiskLevel.next(from: .warning, usage: PerpRiskLevel.warningClearsBelow, distance: nil)
        XCTAssertEqual(step.level, .warning); XCTAssertNil(step.notify)
        step = PerpRiskLevel.next(from: .critical, usage: PerpRiskLevel.criticalClearsBelow, distance: nil)
        XCTAssertEqual(step.level, .critical); XCTAssertNil(step.notify)
        XCTAssertEqual([PerpRiskLevel.warningAt, PerpRiskLevel.warningClearsBelow, PerpRiskLevel.criticalAt, PerpRiskLevel.criticalClearsBelow,
                        PerpRiskLevel.nearLiquidationWithin, PerpRiskLevel.nearLiquidationClearsAbove], [0.80, 0.75, 0.90, 0.85, 0.10, 0.125])
        // A reading that can't be valued changes nothing.
        XCTAssertEqual(walk([(0.85, nil), (nil, nil), (0.85, nil)]), [.warning, nil, nil])
        step = PerpRiskLevel.next(from: .critical, usage: nil, distance: 0.01)
        XCTAssertEqual(step.level, .critical); XCTAssertNil(step.notify)
    }

    /// The mark within 10% of the liquidation price warns when that comes before 80% usage (a position above about 2×);
    /// it re-arms beyond 12.5%. When usage warned first, the mark coming within 10% says nothing more.
    func testNearLiquidationComesFirstOrNotAtAll() {
        XCTAssertEqual(walk([(0.30, 0.15), (0.40, 0.10), (0.45, 0.09), (0.40, 0.12), (0.35, 0.13), (0.40, 0.099)]),
                       [nil, .nearLiquidation, nil, nil, nil, .nearLiquidation])
        // Near first, then the usage warning and the critical one: each is news.
        XCTAssertEqual(walk([(0.50, 0.08), (0.80, 0.02), (0.90, 0.01)]), [.nearLiquidation, .warning, .critical])
        // Usage first (a low-leverage position): the mark then coming within 10% is not a second warning.
        XCTAssertEqual(walk([(0.80, 0.13), (0.85, 0.10), (0.88, 0.07)]), [.warning, nil, nil])
        // A warning that clears to under 75% while the mark is still within 12.5% rests at near, silently.
        XCTAssertEqual(walk([(0.80, 0.11), (0.70, 0.11), (0.70, 0.13), (0.70, 0.10)]), [.warning, nil, nil, .nearLiquidation])

        // The rule matches the leverage it describes: a 1.5× long on a 5% market warns on usage before its mark is within
        // 10%; a 10× long opens about 5% from its liquidation price.
        let low = position(1, .long, size: 1.5, entry: 100, mark: 100, margin: 100)
        XCTAssertGreaterThan(PerpRisk.liquidationDistance(side: .long, mark: 100, liquidation: low.liquidation)!, 0.5)
        let high = position(1, .long, size: 10, entry: 100, mark: 100, margin: 100)
        XCTAssertEqual(PerpRisk.liquidationDistance(side: .long, mark: 100, liquidation: high.liquidation)!, 0.05, accuracy: 1e-12)
    }

    /// A position first seen — at the first read of a session, or just opened — is told only at a warning or critical:
    /// being near the liquidation price from the start is what its ticket showed.
    func testAFirstReadingIsToldOnlyAtAWarning() {
        var step = PerpRiskLevel.next(from: .normal, usage: 0.5, distance: 0.05, firstReading: true)
        XCTAssertEqual(step.level, .nearLiquidation); XCTAssertNil(step.notify)
        step = PerpRiskLevel.next(from: .normal, usage: 0.82, distance: 0.02, firstReading: true)
        XCTAssertEqual(step.level, .warning); XCTAssertEqual(step.notify, .warning)
        step = PerpRiskLevel.next(from: .normal, usage: 0.93, distance: 0.01, firstReading: true)
        XCTAssertEqual(step.notify, .critical)
    }

    /// The watcher's levels per position: once per position per level, deduped across reads; a position that closes or
    /// flips side starts over; one whose market's maintenance can't be read is never warned on a guess.
    func testRiskWatchPerPosition() {
        var watch = PerpRiskWatch()
        let maintenance = [1: 0.05, 2: 0.10]
        // A 10× BTC long opens 5% from liquidation: recorded, not news.
        let opened = position(1, .long, size: 1, entry: 100, mark: 100, margin: 10)
        XCTAssertEqual(watch.update([opened], maintenance: maintenance), [])
        XCTAssertEqual(watch.level(of: 1), .nearLiquidation)
        // The mark falls: usage 5 / (10 − 3.2) = 73.5%, then 5 / (10 − 3.8) = 80.6% — one warning, however many reads.
        XCTAssertEqual(watch.update([position(1, .long, size: 1, entry: 100, mark: 96.8, margin: 10)], maintenance: maintenance), [])
        let warned = position(1, .long, size: 1, entry: 100, mark: 96.2, margin: 10)
        let notices = watch.update([warned], maintenance: maintenance)
        XCTAssertEqual(notices.map(\.level), [.warning])
        XCTAssertEqual(notices.first?.usage ?? 0, 5 / 6.2, accuracy: 1e-12)
        XCTAssertEqual(notices.first?.position, warned)
        for _ in 0..<5 { XCTAssertEqual(watch.update([warned], maintenance: maintenance), [], "the same state is told once") }
        // Critical: 5 / (10 − 4.5) = 90.9%.
        XCTAssertEqual(watch.update([position(1, .long, size: 1, entry: 100, mark: 95.5, margin: 10)], maintenance: maintenance).map(\.level), [.critical])
        // It flips to a short: a new position, a first reading.
        let short = position(1, .short, size: 1, entry: 95.5, mark: 95.5, margin: 9.55)
        XCTAssertEqual(watch.update([short], maintenance: maintenance), [])
        XCTAssertEqual(watch.level(of: 1), .nearLiquidation)
        // Gone: its level goes with it.
        XCTAssertEqual(watch.update([], maintenance: maintenance), [])
        XCTAssertNil(watch.level(of: 1))
        // No maintenance fraction for the market: nothing is evaluated, nothing recorded.
        let unknown = position(3, .long, size: 1, entry: 100, mark: 91, margin: 10, maintenance: nil)
        XCTAssertEqual(watch.update([unknown], maintenance: maintenance), [])
        XCTAssertNil(watch.level(of: 3))
        // Two positions, each its own level.
        let two = [position(1, .long, size: 1, entry: 100, mark: 96.2, margin: 10), position(2, .short, size: 1, entry: 100, mark: 107.5, margin: 20, maintenance: 0.10)]
        XCTAssertEqual(watch.update(two, maintenance: maintenance).map(\.level), [.warning, .warning], "two first readings at a warning: 80.6% and 10 / 12.5 = 80%")
        watch.reset()
        XCTAssertNil(watch.level(of: 1))
    }

    // MARK: - Fills and endings

    /// The first read only records; a position that opens, grows or flips side filled an order; one that shrinks did not;
    /// one gone from both the read and the account's position bitmap ended, and one the read left out but the bitmap still
    /// holds is remembered until it really ends.
    func testFillsAndEndings() {
        var watch = PerpPositionWatch()
        let btc = position(1, .long, size: 1, entry: 100, mark: 100, margin: 10)
        XCTAssertEqual(watch.update([btc], stillOpen: [1]), .init(), "what was open at the first read isn't news")
        let grown = position(1, .long, size: 1.5, entry: 100, mark: 100, margin: 15)
        XCTAssertEqual(watch.update([grown], stillOpen: [1]).filled, [grown])
        XCTAssertEqual(watch.update([grown], stillOpen: [1]), .init(), "the mark moving, or nothing, is no fill")
        let eth = position(20, .short, size: 2, entry: 2000, mark: 2000, margin: 400)
        XCTAssertEqual(watch.update([grown, eth], stillOpen: [1, 20]).filled, [eth], "a new position")
        let shrunk = position(20, .short, size: 1, entry: 2000, mark: 2000, margin: 200)
        XCTAssertEqual(watch.update([grown, shrunk], stillOpen: [1, 20]), .init(), "a partial close is not a fill")
        let flipped = position(20, .long, size: 0.5, entry: 2000, mark: 2000, margin: 100)
        XCTAssertEqual(watch.update([grown, flipped], stillOpen: [1, 20]).filled, [flipped], "a flip opened a new side")
        // The read leaves BTC out but the bitmap still holds it: not ended.
        XCTAssertEqual(watch.update([flipped], stillOpen: [1, 20]), .init())
        // Now it is gone from both: ended, as it was when last read.
        XCTAssertEqual(watch.update([flipped], stillOpen: [20]).ended, [grown])
        XCTAssertEqual(watch.update([], stillOpen: []).ended, [flipped])
        XCTAssertEqual(watch.update([], stillOpen: []), .init())
    }

    /// One ending, one notice. The trading stream reports a liquidation, a deleveraging or a fired TP/SL the moment it
    /// happens; the watcher then says nothing. While the stream is live the watcher waits for it, then reports what the
    /// stream didn't explain; without the stream it reports at once. A close sent from this app is never news.
    func testEndingDedupeWithTheStream() {
        /// `seconds` after the watcher saw it gone; the user's close `closedAgo` seconds before then.
        func decide(_ seconds: TimeInterval, closedAgo: TimeInterval? = nil, explained: Bool = false, live: Bool = true, resting: Bool = false) -> PerpEndingNotice {
            let now = t0.addingTimeInterval(seconds)
            return PerpEndingNotice.decide(endedAt: t0, now: now, userClosedAt: closedAgo.map { now.addingTimeInterval(-$0) },
                                           explainedByStream: explained, streamLive: live, restingClose: resting)
        }
        // Liquidated with the stream live: the watcher sees the position gone first, waits, and by its next read the stream
        // has posted "Position liquidated": nothing more.
        XCTAssertEqual(decide(0), .wait)
        XCTAssertEqual(decide(15, explained: true), .quiet)
        // Explained before the watcher even saw it gone.
        XCTAssertEqual(decide(0, explained: true), .quiet)
        // Closed on another device with the stream live: nothing explains it, so the watcher's next read reports it.
        XCTAssertEqual(decide(9), .wait)
        XCTAssertEqual(decide(15), .closed)
        XCTAssertEqual(decide(15, resting: true), .closeOrderFilled)
        // No stream (no one-click trading, or a dropped socket): reported at once — "closed", since only the stream can say
        // it was a liquidation.
        XCTAssertEqual(decide(0, live: false), .closed)
        XCTAssertEqual(decide(0, live: false, resting: true), .closeOrderFilled)
        // Closed from this app: quiet for ten minutes, then news again.
        XCTAssertEqual(decide(15, closedAgo: 45), .quiet)
        XCTAssertEqual(decide(0, closedAgo: 30, live: false), .quiet)
        XCTAssertEqual(decide(15, closedAgo: PerpEndingNotice.userCloseWindow - 1), .quiet)
        XCTAssertEqual(decide(15, closedAgo: PerpEndingNotice.userCloseWindow), .closed)
        XCTAssertEqual(PerpEndingNotice.streamGrace, 10)
        XCTAssertLessThan(PerpEndingNotice.streamGrace, AlertLoop.perpsInterval, "a wait ends by the watcher's next read")

        let gone = position(1, .long, size: 1.5, entry: 100, mark: 100, margin: 15)
        XCTAssertNil(PerpAlertText.ending(.wait, position: gone, asset: "BTC"))
        XCTAssertNil(PerpAlertText.ending(.quiet, position: gone, asset: "BTC"))
        XCTAssertEqual(PerpAlertText.ending(.closeOrderFilled, position: gone, asset: "BTC")?.title, "Close order filled")
        XCTAssertEqual(PerpAlertText.ending(.closed, position: gone, asset: "BTC")?.title, "BTC-PERP long closed")
        XCTAssertTrue(PerpAlertText.ending(.closed, position: gone, asset: "BTC")!.body.contains("It may have hit a take-profit or stop-loss, been liquidated"))
    }

    /// An order closes a position when it is reduce-only or on the other side of it: Perpl nets a Short against a long
    /// (and a Long against a short), so a plain opposite order sent from this app is the user's own close, never "closed
    /// from elsewhere", and a resting one that fills is a close order filled. One bigger than the position turns it
    /// around: the new position's ending is news.
    func testOppositeOrdersAreCloses() {
        // Sent from the ticket.
        XCTAssertEqual(PerpCloseOrder.closes(orderSide: .short, reduceOnly: false, held: .long), .long, "a Short market order against a long")
        XCTAssertEqual(PerpCloseOrder.closes(orderSide: .long, reduceOnly: false, held: .short), .short)
        XCTAssertNil(PerpCloseOrder.closes(orderSide: .short, reduceOnly: false, held: .short), "adds to the position")
        XCTAssertNil(PerpCloseOrder.closes(orderSide: .long, reduceOnly: false, held: nil), "opens one")
        XCTAssertEqual(PerpCloseOrder.closes(orderSide: .short, reduceOnly: true, held: .long), .long)
        XCTAssertEqual(PerpCloseOrder.closes(orderSide: .long, reduceOnly: true, held: nil), .short, "reduce-only always closes")

        // Resting on the account.
        func order(_ perpId: Int, _ type: PerpOrderType) -> PerpOrder {
            PerpOrder(perpId: perpId, orderId: perpId * 10, symbol: "M\(perpId)", type: type, side: type == .openLong || type == .closeShort ? .buy : .sell,
                      price: 100, size: 1, leverage: 5, expiryBlock: 0, reduceOnly: type == .closeLong || type == .closeShort)
        }
        let held = [position(1, .long, size: 1, entry: 100, mark: 100, margin: 10), position(2, .long, size: 1, entry: 100, mark: 100, margin: 10),
                    position(3, .long, size: 1, entry: 100, mark: 100, margin: 10), position(4, .short, size: 1, entry: 100, mark: 100, margin: 10)]
        let orders = [order(1, .closeLong), order(2, .openShort), order(3, .openLong), order(4, .openLong), order(5, .openShort)]
        XCTAssertEqual(PerpCloseOrder.restingCloseMarkets(orders: orders, positions: held), [1, 2, 4],
                       "reduce-only, a sell against a long, a buy against a short; not one that adds (3) or one with no position (5)")
        XCTAssertTrue(PerpCloseOrder.closes(order(6, .closeShort), held: nil))
        XCTAssertFalse(PerpCloseOrder.closes(order(6, .openLong), held: nil))

        // The reviewer's case: a 1 BTC long, the stream live, a 1 BTC Short market order (not reduce-only) from the ticket.
        var closes = PerpUserCloses()
        let long = position(1, .long, size: 1, entry: 100, mark: 100, margin: 10)
        closes.note(1, closing: PerpCloseOrder.closes(orderSide: .short, reduceOnly: false, held: .long)!, at: t0)
        var watch = PerpPositionWatch()
        _ = watch.update([long], stillOpen: [1])
        let ended = watch.update([], stillOpen: []).ended
        XCTAssertEqual(ended, [long])
        XCTAssertEqual(closes.closedAt(long), t0)
        XCTAssertEqual(PerpEndingNotice.decide(endedAt: t0.addingTimeInterval(5), now: t0.addingTimeInterval(20), userClosedAt: closes.closedAt(ended[0]),
                                               explainedByStream: false, streamLive: true, restingClose: false), .quiet,
                       "the user's own close: no 'wasn't closed from this app'")

        // A 2 BTC Short against the 1 BTC long turned it around: the short that ends later (another device) is news.
        let short = position(1, .short, size: 1, entry: 100, mark: 100, margin: 10)
        XCTAssertNil(closes.closedAt(short))
        XCTAssertEqual(PerpEndingNotice.decide(endedAt: t0.addingTimeInterval(60), now: t0.addingTimeInterval(75), userClosedAt: closes.closedAt(short),
                                               explainedByStream: false, streamLive: true, restingClose: false), .closed)
        XCTAssertNil(closes.closedAt(position(2, .long, size: 1, entry: 100, mark: 100, margin: 10)), "another market")
        closes.forget(1)
        XCTAssertNil(closes.closedAt(long), "a close that never left the device")

        // An opposite limit that rested and filled after the window: a close order filled, not "closed".
        XCTAssertEqual(PerpEndingNotice.decide(endedAt: t0, now: t0.addingTimeInterval(15), userClosedAt: nil, explainedByStream: false, streamLive: true,
                                               restingClose: PerpCloseOrder.restingCloseMarkets(orders: [order(1, .openShort)], positions: [long]).contains(1)),
                       .closeOrderFilled)
    }

    // MARK: - Words

    /// Each level's title, the numbers in the one price style, and a watched wallet's alerts never suggest an action.
    func testRiskText() throws {
        let p = position(1, .long, size: 1, entry: 100, mark: 96.2, margin: 10)
        let warning = PerpRiskNotice(position: p, level: .warning, usage: 5 / 6.2, distance: 0.012)
        var text = PerpAlertText.risk(warning, asset: "BTC", canAct: true)
        XCTAssertEqual(text.title, "Margin warning: BTC-PERP long")
        XCTAssertEqual(text.body, "80% of its margin is in use. Mark $96.20, liquidation $95.00. Add margin or reduce the position on Perps to stay clear of it.")
        text = PerpAlertText.risk(PerpRiskNotice(position: p, level: .critical, usage: 0.934, distance: 0.01), asset: "BTC", canAct: true)
        XCTAssertEqual(text.title, "Liquidation risk: BTC-PERP long")
        XCTAssertTrue(text.body.hasPrefix("93% of its margin is in use, and Perpl liquidates at 100%."))
        XCTAssertTrue(text.body.hasSuffix("Add margin or reduce the position now."))
        text = PerpAlertText.risk(PerpRiskNotice(position: p, level: .critical, usage: .infinity, distance: 0), asset: "BTC", canAct: true)
        XCTAssertTrue(text.body.hasPrefix("All of its margin is in use"))
        // No reading, however large, traps converting to a whole percent (Int.max is about 9.2e18).
        for huge in [1e17, 9.3e16, 1e19, 5e15, 1e300, Double.greatestFiniteMagnitude] {
            XCTAssertTrue(PerpAlertText.risk(PerpRiskNotice(position: p, level: .critical, usage: huge, distance: 0), asset: "BTC", canAct: true)
                .body.hasPrefix("All of its margin is in use"), "\(huge)")
        }
        XCTAssertEqual(PerpAlertText.usageText(9.999), "999%")
        XCTAssertEqual(PerpAlertText.usageText(10), "All")
        XCTAssertEqual(PerpAlertText.usageText(1.5), "150%")
        XCTAssertEqual(PerpAlertText.usageText(0.899), "89%")
        // A first reading of a position whose equity is a residue next to zero: critical, said as "All", no crash.
        var watch = PerpRiskWatch()
        let residue = position(1, .long, size: 1, entry: 100, mark: 100, margin: 1e-15)
        let notices = watch.update([residue], maintenance: [1: 0.05])
        XCTAssertEqual(notices.map(\.level), [.critical])
        XCTAssertTrue(PerpAlertText.risk(try XCTUnwrap(notices.first), asset: "BTC", canAct: true).body.hasPrefix("All of its margin is in use"))
        text = PerpAlertText.risk(PerpRiskNotice(position: p, level: .nearLiquidation, usage: 0.5, distance: 0.08), asset: "BTC", canAct: true)
        XCTAssertEqual(text.title, "Near liquidation: BTC-PERP long")
        XCTAssertTrue(text.body.hasPrefix("The mark, $96.20, is within 10% of the liquidation price, $95.00."))

        for level in [PerpRiskLevel.nearLiquidation, .warning, .critical] {
            let watched = PerpAlertText.risk(PerpRiskNotice(position: p, level: level, usage: 0.9, distance: 0.05), asset: "BTC", canAct: false)
            XCTAssertFalse(watched.body.contains("Add margin"), "\(level)")
            XCTAssertFalse(watched.body.contains("reduce"), "\(level)")
            XCTAssertTrue(watched.body.hasSuffix("You're watching this wallet: DyorHQ can't change its positions."), "\(level)")
        }
    }

    /// A Perps alert's record names its market, so a tap opens it; nothing else reads as a market.
    func testTheReferenceOpensTheMarket() {
        XCTAssertEqual(PerpAlertText.reference(perpId: 31), "perp:31")
        for id in [0, 1, 31, 90, 765] { XCTAssertEqual(PerpAlertText.market(reference: PerpAlertText.reference(perpId: id)), id) }
        for other in [nil, "", "31", "perp:", "perp:-1", "perp:1e3", "perp: 1", "perp:٣", "perp:1234567", "PERP:1", "moment:3", "0x1111111111111111111111111111111111111111"] {
            XCTAssertNil(PerpAlertText.market(reference: other), other ?? "nil")
        }
    }

    // MARK: - Switches

    /// Fills post only with "Enable Notifications" and "Swaps & Fills" both on (the known gap: the position read posted
    /// them regardless); price alerts and margin warnings are checked only with their own switch and the master on.
    func testTheSwitches() {
        for enabled in [false, true] {
            for fills in [false, true] {
                for price in [false, true] {
                    for margin in [false, true] {
                        let prefs = AlertPreferences(notificationsEnabled: enabled, fills: fills, priceAlerts: price, marginWarnings: margin)
                        XCTAssertEqual(prefs.postsFills, enabled && fills)
                        XCTAssertEqual(prefs.checksPriceAlerts, enabled && price)
                        XCTAssertEqual(prefs.checksMargin, enabled && margin)
                    }
                }
            }
        }
    }

    // MARK: - Price alerts

    /// At or past the target fires; a price that can't be read never does, and neither does a target that isn't one.
    func testPriceAlertCrossing() {
        XCTAssertTrue(PriceAlertCheck.crossed(above: true, target: 2, price: 2))
        XCTAssertTrue(PriceAlertCheck.crossed(above: true, target: 2, price: 2.01))
        XCTAssertFalse(PriceAlertCheck.crossed(above: true, target: 2, price: 1.99))
        XCTAssertTrue(PriceAlertCheck.crossed(above: false, target: 2, price: 2))
        XCTAssertTrue(PriceAlertCheck.crossed(above: false, target: 2, price: 1.5))
        XCTAssertFalse(PriceAlertCheck.crossed(above: false, target: 2, price: 2.5))
        // Dust targets keep their digits.
        XCTAssertTrue(PriceAlertCheck.crossed(above: false, target: 6.13e-8, price: 6.12e-8))
        XCTAssertFalse(PriceAlertCheck.crossed(above: false, target: 6.13e-8, price: 6.14e-8))
        for price in [nil, 0, -1, Double.nan, Double.infinity, -Double.infinity] as [Double?] {
            XCTAssertFalse(PriceAlertCheck.crossed(above: false, target: 2, price: price), "\(String(describing: price))")
            XCTAssertFalse(PriceAlertCheck.crossed(above: true, target: 2, price: price), "\(String(describing: price))")
        }
        for target in [0, -1, .nan, .infinity] as [Double] {
            XCTAssertFalse(PriceAlertCheck.crossed(above: true, target: target, price: 5), "\(target)")
            XCTAssertFalse(PriceAlertCheck.crossed(above: false, target: target, price: 5), "\(target)")
        }
    }

    /// Which alerts fire on a read: only those crossed, never one whose price wasn't read, never one this run already
    /// fired, and none at all when the account signed in now isn't the one the read was for.
    func testPriceAlertsFireOnceForTheAccountSignedIn() {
        let mon = Address(literal: "0x3333333333333333333333333333333333333333")
        let qt = Address(literal: "0x4444444444444444444444444444444444444444")
        let unread = Address(literal: "0x5555555555555555555555555555555555555555")
        let up = PriceAlertCheck.Alert(id: UUID(), token: mon, target: 0.03, above: true)
        let down = PriceAlertCheck.Alert(id: UUID(), token: qt, target: 0.001, above: false)
        let notYet = PriceAlertCheck.Alert(id: UUID(), token: mon, target: 0.05, above: true)
        let noPrice = PriceAlertCheck.Alert(id: UUID(), token: unread, target: 1, above: false)
        let alerts = [up, down, notYet, noPrice]
        let prices = [mon: 0.031, qt: 0.0009]
        XCTAssertEqual(PriceAlertCheck.firing(alerts, prices: prices, readFor: a, signedIn: a), [up, down])
        // An account switch or a sign-out during the read: nothing fires (and so nothing is removed).
        XCTAssertEqual(PriceAlertCheck.firing(alerts, prices: prices, readFor: a, signedIn: b), [])
        XCTAssertEqual(PriceAlertCheck.firing(alerts, prices: prices, readFor: a, signedIn: nil), [])
        // Fired once: the next read, before the removal is read back, doesn't fire it again.
        XCTAssertEqual(PriceAlertCheck.firing(alerts, prices: prices, readFor: a, signedIn: a, alreadyFired: [up.id]), [down])
        // Nothing read: nothing fires.
        XCTAssertEqual(PriceAlertCheck.firing(alerts, prices: [:], readFor: a, signedIn: a), [])
    }

    // MARK: - The watcher loop

    /// One loop at a time: the account signed in starts a run, the same account keeps it, a switch or a sign-out ends it,
    /// and only the newest run may post, for its own account.
    func testOneLoopThatStopsOnSignOutAndSwitch() {
        var loop = AlertLoop()
        XCTAssertEqual(loop.bind(nil), .keep, "nothing to stop at launch")
        XCTAssertEqual(loop.bind(a), .start(run: 1))
        XCTAssertTrue(loop.mayPost(run: 1, owner: a))
        for _ in 0..<3 { XCTAssertEqual(loop.bind(a), .keep, "never a second loop for the same account") }
        // A switch: the old run can't post, even for its own account.
        XCTAssertEqual(loop.bind(b), .start(run: 2))
        XCTAssertFalse(loop.mayPost(run: 1, owner: a))
        XCTAssertFalse(loop.mayPost(run: 2, owner: a))
        XCTAssertTrue(loop.mayPost(run: 2, owner: b))
        // A sign-out: nothing may post.
        XCTAssertEqual(loop.bind(nil), .stop)
        XCTAssertFalse(loop.mayPost(run: 2, owner: b))
        XCTAssertEqual(loop.bind(nil), .keep)
        // Signing back in to the first account is a new run: the run from before the switch stays stopped.
        XCTAssertEqual(loop.bind(a), .start(run: 4))
        XCTAssertFalse(loop.mayPost(run: 1, owner: a))
        XCTAssertTrue(loop.mayPost(run: 4, owner: a))
    }

    /// Price alerts at least every 45 seconds (30), positions every 15, and both at once on a return to the foreground.
    func testTheCadence() {
        XCTAssertLessThanOrEqual(AlertLoop.priceInterval, 45)
        XCTAssertEqual(AlertLoop.priceInterval, 30)
        XCTAssertEqual(AlertLoop.perpsInterval, 15)
        XCTAssertTrue(AlertLoop.due(last: nil, interval: 30, now: t0, woke: false), "never checked")
        XCTAssertFalse(AlertLoop.due(last: t0, interval: 30, now: t0.addingTimeInterval(16), woke: false))
        XCTAssertTrue(AlertLoop.due(last: t0, interval: 30, now: t0.addingTimeInterval(30), woke: false))
        XCTAssertTrue(AlertLoop.due(last: t0, interval: 30, now: t0.addingTimeInterval(1), woke: true), "back in the foreground")
    }
}
