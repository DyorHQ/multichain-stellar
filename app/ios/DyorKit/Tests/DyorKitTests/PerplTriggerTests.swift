import BigInt
import XCTest
@testable import DyorKit

/// Take-profit / stop-loss rules, the frame guard that keeps a `tp: 0` close off the wire, the trading stream's
/// trigger and position events, and orphan detection.
@MainActor
final class PerplTriggerTests: XCTestCase {
    private func btc() -> PerpMarket {
        PerpMarket(id: 1, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0,
                   mark: 95000, last: 95000, oracle: 95000, markTimestamp: 0, longOI: 0, shortOI: 0,
                   fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
    }

    // MARK: Trigger price rules

    func testTicks() {
        XCTAssertEqual(PerplTriggerRules.ticks(95000.1, decimals: 1), 950001) // 950001.0000000001 in binary
        XCTAssertEqual(PerplTriggerRules.ticks(0.1, decimals: 1), 1)
        XCTAssertEqual(PerplTriggerRules.ticks(0.031234, decimals: 6), 31234)
        XCTAssertNil(PerplTriggerRules.ticks(95000.05, decimals: 1), "half a tick is off the grid")
        XCTAssertNil(PerplTriggerRules.ticks(0.04, decimals: 1), "below one tick")
        XCTAssertNil(PerplTriggerRules.ticks(0, decimals: 1))
        XCTAssertNil(PerplTriggerRules.ticks(-1, decimals: 1))
        XCTAssertNil(PerplTriggerRules.ticks(.infinity, decimals: 1))
    }

    func testZeroNegativeAndSubTickPricesAreTooLow() {
        for price in [0, -5, 0.04] {
            XCTAssertEqual(PerplTriggerRules.problem(.stopLoss, price: price, side: .long, reference: 95000, liquidation: nil, priceDecimals: 1),
                           .tooLow(.stopLoss, minimum: 0.1), "\(price)")
            XCTAssertEqual(PerplTriggerRules.problem(.takeProfit, price: price, side: .short, reference: 95000, liquidation: nil, priceDecimals: 1),
                           .tooLow(.takeProfit, minimum: 0.1), "\(price)")
        }
        XCTAssertEqual(PerplTriggerRules.problem(.takeProfit, price: 90000.05, side: .short, reference: 95000, liquidation: nil, priceDecimals: 1),
                       .offTick(.takeProfit, decimals: 1))
        XCTAssertEqual(PerplTriggerRules.problem(.takeProfit, price: 1e300, side: .long, reference: 95000, liquidation: nil, priceDecimals: 1),
                       .outOfRange(.takeProfit))
    }

    func testSides() {
        let rules = { (kind: PerplTriggerKind, price: Double, side: PositionSide) in
            PerplTriggerRules.problem(kind, price: price, side: side, reference: 95000, liquidation: nil, priceDecimals: 1)
        }
        XCTAssertNil(rules(.takeProfit, 100000, .long))
        XCTAssertNil(rules(.stopLoss, 90000, .long))
        XCTAssertNil(rules(.takeProfit, 90000, .short))
        XCTAssertNil(rules(.stopLoss, 100000, .short))
        XCTAssertEqual(rules(.takeProfit, 90000, .long), .wrongSide(.takeProfit, side: .long, reference: 95000))
        XCTAssertEqual(rules(.stopLoss, 100000, .long), .wrongSide(.stopLoss, side: .long, reference: 95000))
        XCTAssertEqual(rules(.takeProfit, 100000, .short), .wrongSide(.takeProfit, side: .short, reference: 95000))
        XCTAssertEqual(rules(.stopLoss, 90000, .short), .wrongSide(.stopLoss, side: .short, reference: 95000))
        XCTAssertEqual(rules(.stopLoss, 95000, .long), .wrongSide(.stopLoss, side: .long, reference: 95000), "at the reference fires at once")
        // No reference (no price yet): the side can't be judged, the price itself still can.
        XCTAssertNil(PerplTriggerRules.problem(.takeProfit, price: 1, side: .long, reference: 0, liquidation: nil, priceDecimals: 1))
    }

    func testStopLossMustSitInsideLiquidation() {
        // Long at 95,000, liquidated at 86,000: a stop at or below 86,000 never fires before liquidation.
        XCTAssertNil(PerplTriggerRules.problem(.stopLoss, price: 86000.1, side: .long, reference: 95000, liquidation: 86000, priceDecimals: 1))
        XCTAssertEqual(PerplTriggerRules.problem(.stopLoss, price: 86000, side: .long, reference: 95000, liquidation: 86000, priceDecimals: 1),
                       .beyondLiquidation(side: .long, liquidation: 86000))
        XCTAssertEqual(PerplTriggerRules.problem(.stopLoss, price: 80000, side: .long, reference: 95000, liquidation: 86000, priceDecimals: 1),
                       .beyondLiquidation(side: .long, liquidation: 86000))
        // Short at 95,000, liquidated at 104,000.
        XCTAssertNil(PerplTriggerRules.problem(.stopLoss, price: 103999.9, side: .short, reference: 95000, liquidation: 104000, priceDecimals: 1))
        XCTAssertEqual(PerplTriggerRules.problem(.stopLoss, price: 110000, side: .short, reference: 95000, liquidation: 104000, priceDecimals: 1),
                       .beyondLiquidation(side: .short, liquidation: 104000))
        // A take-profit is on the other side of the entry from liquidation: never judged against it.
        XCTAssertNil(PerplTriggerRules.problem(.takeProfit, price: 120000, side: .long, reference: 95000, liquidation: 86000, priceDecimals: 1))
    }

    func testMessages() {
        let m = btc()
        XCTAssertEqual(PerplTriggerRules.Problem.tooLow(.stopLoss, minimum: 0.1).message(market: m), "Stop-loss must be at least 0.1 on BTC.")
        // One key for any count: what 1 reads is the catalog's plural form (the key itself under `swift test`).
        XCTAssertEqual(PerplTriggerRules.Problem.offTick(.takeProfit, decimals: 1).message(market: m), L10n.tr("Take-profit can have at most \(1) decimal places on \("BTC")."))
        XCTAssertEqual(PerplTriggerRules.Problem.offTick(.takeProfit, decimals: 3).message(market: m), "Take-profit can have at most 3 decimal places on BTC.")
        XCTAssertEqual(PerplTriggerRules.Problem.offTick(.takeProfit, decimals: 0).message(market: m), "Take-profit must be a whole number on BTC.")
        XCTAssertEqual(PerplTriggerRules.Problem.wrongSide(.takeProfit, side: .short, reference: 950).message(market: m), "Take-profit must be below your entry (950) for a short.")
        XCTAssertEqual(PerplTriggerRules.Problem.wrongSide(.stopLoss, side: .long, reference: 950).message(market: m, referenceName: "the mark price"),
                       "Stop-loss must be below the mark price (950) for a long.")
        XCTAssertTrue(PerplTriggerRules.Problem.beyondLiquidation(side: .short, liquidation: 990).message(market: m).hasPrefix("Stop-loss must be below the liquidation price (990)."))
    }

    // MARK: Frame guard

    func testZeroTriggerPriceNeverLeavesTheDevice() {
        // A stop-loss typed as 0.01 on BTC (one decimal) scales to tp: 0 — a reduce-only market close that would
        // execute the moment it is admitted.
        let subTick = PerplOrders.stopLoss(side: .long, price: 0.01, size: 0.1, market: btc(), accountId: 1, linkedPositionId: nil)
        XCTAssertEqual(subTick.triggerPricePNS, 0)
        XCTAssertNotNil(PerplOrders.problem(subTick))
        let zero = PerplOrders.takeProfit(side: .short, price: 0, size: 0.1, market: btc(), accountId: 1, linkedPositionId: nil)
        XCTAssertNotNil(PerplOrders.problem(zero))
        let noSize = PerplOrders.takeProfit(side: .long, price: 100000, size: 0.000001, market: btc(), accountId: 1, linkedPositionId: nil)
        XCTAssertNotNil(PerplOrders.problem(noSize), "size below one lot")
        XCTAssertNil(PerplOrders.problem(PerplOrders.takeProfit(side: .long, price: 100000, size: 0.1, market: btc(), accountId: 1, linkedPositionId: 7)))
        XCTAssertNil(PerplOrders.problem(PerplOrders.stopLoss(side: .short, price: 100000, size: 0.1, market: btc(), accountId: 1, linkedPositionId: nil)))
    }

    func testZeroPriceLimitIsRefusedButMarketIsNot() {
        let limit = PerplOrders.entry(OrderInput(market: btc(), side: .long, kind: .limit, size: 0.1, price: 0.01, leverage: 5), accountId: 1, head: 0)
        XCTAssertEqual(limit.pricePNS, 0)
        XCTAssertNotNil(PerplOrders.problem(limit), "a GTC order with p: 0 is a market order")
        XCTAssertNil(PerplOrders.problem(PerplOrders.entry(OrderInput(market: btc(), side: .long, kind: .market, size: 0.1, leverage: 5), accountId: 1, head: 0)))
        XCTAssertNil(PerplOrders.problem(PerplOrders.cancel(perpId: 1, orderId: 9, accountId: 1, head: 0)))
    }

    // MARK: Trading stream

    private func client() -> PerplTradeClient {
        PerplTradeClient(key: PerplApiKey(token: "t", secret: Data(repeating: 7, count: 32), address: "0x0000000000000000000000000000000000000001", scopeMask: 2))
    }

    private func frame(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func trigger(oid: Int, st: Int, sr: Int = 0, removed: Bool = false, tpc: Int = 4, market: Int = 1) -> [String: Any] {
        var order: [String: Any] = ["oid": oid, "mkt": market, "t": 3, "st": st, "sr": sr, "p": 0, "os": 10000, "fs": 0, "tp": 900000, "tpc": tpc, "lv": 0]
        if removed { order["r"] = true }
        return order
    }

    func testTriggerEventsComeFromUpdatesOnceEach() {
        let c = client()
        var events: [PerplTriggerEvent] = []
        c.onTriggerEvent = { events.append($0) }
        XCTAssertFalse(c.hasOrdersSnapshot)

        // A trigger already Triggered in the snapshot is state, not news.
        c.handle(frame(["mt": 23, "d": [trigger(oid: 5, st: 8), trigger(oid: 6, st: 9)]]))
        XCTAssertTrue(c.hasOrdersSnapshot)
        XCTAssertEqual(c.openOrders.map(\.oid), [5, 6])
        XCTAssertTrue(events.isEmpty)
        // An update that leaves out the status keeps the order live, with the status it had.
        c.handle(frame(["mt": 24, "d": [["oid": 5, "fs": 0]]]))
        XCTAssertEqual(c.openOrders.map(\.oid), [5, 6])
        XCTAssertEqual(c.openOrders.first?.statusRaw, 8)

        // Fires: Triggered, then Executed and removed — one event.
        c.handle(frame(["mt": 24, "d": [["oid": 5, "st": 9, "sr": 54]]]))
        c.handle(frame(["mt": 24, "d": [["oid": 5, "st": 10, "sr": 65, "r": true]]]))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, .triggered)
        // The partial update kept the order's own terms (market, type, trigger).
        XCTAssertEqual(events.first?.order.marketId, 1)
        XCTAssertEqual(events.first?.order.triggerPriceRaw, 900000)
        XCTAssertEqual(events.first?.order.isStopLoss, true)
        XCTAssertEqual(c.openOrders.map(\.oid), [6])

        // Fails to execute after firing: reported, with Perpl's reason.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 6, st: 7, sr: 64, removed: true)]]))
        XCTAssertEqual(events.last?.outcome, .failed(reason: 64))
        XCTAssertTrue(c.openOrders.isEmpty)

        // A cancelled trigger and a plain limit order that fills report nothing.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 7, st: 8)]]))
        c.handle(frame(["mt": 24, "d": [trigger(oid: 7, st: 5, removed: true)]]))
        c.handle(frame(["mt": 24, "d": [["oid": 8, "mkt": 1, "t": 1, "st": 4, "p": 950000, "os": 10000, "fs": 10000, "lv": 500]]]))
        XCTAssertEqual(events.count, 2)
    }

    func testPositionsAndEndings() {
        let c = client()
        var ended: [PerplLivePosition] = []
        c.onPositionEnded = { ended.append($0) }
        c.handle(frame(["mt": 26, "d": [["pid": 41, "mkt": 1, "sd": 1, "s": 20000, "st": 1], ["pid": 42, "mkt": 20, "sd": 2, "s": 5, "st": 1]]]))
        XCTAssertTrue(c.hasPositionsSnapshot)
        XCTAssertEqual(c.positions.map(\.pid), [41, 42])
        XCTAssertEqual(c.positions.first?.isLong, true)
        XCTAssertEqual(c.positions.last?.isLong, false)

        c.handle(frame(["mt": 27, "d": [["pid": 41, "st": 3, "sr": 19, "s": 0]]]))
        XCTAssertEqual(c.positions.map(\.pid), [42])
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.wasLiquidated, true)
        XCTAssertEqual(ended.first?.marketId, 1, "an update's missing fields come from the position it updates")
        XCTAssertEqual(ended.first?.isLong, true)

        // Reported once; a still-open update reports nothing; a side-less unknown position is ignored.
        c.handle(frame(["mt": 27, "d": [["pid": 41, "st": 3, "sr": 19, "s": 0]]]))
        c.handle(frame(["mt": 27, "d": [["pid": 42, "st": 1, "s": 9]]]))
        c.handle(frame(["mt": 27, "d": [["pid": 99, "st": 2, "s": 0]]]))
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(c.positions.first?.sizeRaw, 9)
    }

    #if DEBUG
    /// The scripted demo's client (p4 spec D, #13): only `debugScripted()` makes one, it can't route anywhere, and its drop
    /// is a dropped socket's — signed out, every outcome wait ended as "connection lost", the owner told.
    func testTheDemoClientIsScriptedAndDropsAsASocketWould() async throws {
        XCTAssertFalse(client().isDebugScripted, "a client built with a key is never scripted")
        let demo = PerplTradeClient.debugScripted()
        XCTAssertTrue(demo.isDebugScripted)
        var written: [String] = []
        demo.debugAttach { written.append($0) }
        XCTAssertTrue(written.isEmpty)
        demo.debugReceive(#"{"mt":19,"sn":9,"as":[{"id":10,"lfr":5,"fw":true}]}"#)
        XCTAssertTrue(demo.signedIn)
        var dropped = 0
        demo.onDisconnect = { dropped += 1 }
        let send = Task { try await demo.sendEach([cancelFrame()]) }
        await until { written.count == 1 }
        demo.debugReceive(#"{"mt":3,"cid":1,"status":{"code":0}}"#)
        let sendAcks = try await send.value
        let rq = try XCTUnwrap(sendAcks.first?.requestId)
        let sent = try XCTUnwrap(demo.sentRequest(rq: rq))
        let wait = Task { await demo.awaitOutcome(rq: rq, sent: sent, deadline: PerplOutcomeDeadline(ackHead: nil, ttlBlocks: nil, ackAt: Date(), cap: 60)) }
        await until { demo.hasRequestsInFlight }
        XCTAssertTrue(demo.hasRequestsInFlight, "the outcome is waited for")
        demo.debugDrop()
        XCTAssertFalse(demo.signedIn)
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(demo.lastClose?.code, 1001)
        let outcome = await wait.value
        XCTAssertEqual(outcome, .unconfirmed(.connectionLost))
        XCTAssertFalse(demo.hasRequestsInFlight)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DyorKit/Services/Perpl/PerplTradeClient.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("precondition(!isDebugScripted, \"a scripted demo client never connects\")"))
        XCTAssertTrue(source.contains("URL(string: \"wss://perps-demo.invalid\")!"))
    }
    #endif

    func testNothingInFlightOnAFreshClient() async {
        let c = client()
        XCTAssertFalse(c.hasRequestsInFlight)
        do {
            _ = try await c.sendEach([PerplOrders.cancel(perpId: 1, orderId: 3, accountId: 1, head: 0)])
            XCTFail("not signed in")
        } catch let error as PerplTradeError {
            XCTAssertFalse(error.outcomeUnknown, "nothing was sent")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertFalse(c.hasRequestsInFlight)
    }

    func testUnknownAckIsNotAccepted() {
        XCTAssertTrue(PerplOrderAck(code: 0, error: nil).accepted)
        XCTAssertFalse(PerplOrderAck(code: 0, error: nil, outcomeUnknown: true).accepted)
        XCTAssertFalse(PerplOrderAck(code: 400, error: "bad").accepted)
        XCTAssertFalse(PerplTradeError.invalidOrder("x").outcomeUnknown)
        XCTAssertTrue(PerplTradeError.closed("x").outcomeUnknown)
    }

    // MARK: Orphans

    private func order(oid: Int, market: Int = 1, type: Int, tp: Int? = 900000, tpc: Int? = 4) -> PerplOpenOrder {
        PerplOpenOrder(oid: oid, marketId: market, typeRaw: type, statusRaw: 8, priceRaw: 0, sizeRaw: 10000, filledRaw: 0,
                       triggerPriceRaw: tp, triggerConditionRaw: tpc, linkedPositionId: nil, leverageHundredths: 0)
    }

    func testOrphansAndSiblings() {
        let longSL = order(oid: 1, type: 3)                       // CloseLong stop on BTC
        let longTP = order(oid: 2, type: 3, tp: 1_100_000, tpc: 1) // CloseLong take-profit on BTC
        let shortSL = order(oid: 3, type: 4, tpc: 3)               // CloseShort on BTC
        let ethSL = order(oid: 4, market: 20, type: 3)             // CloseLong on ETH
        let orders = [longSL, longTP, shortSL, ethSL]
        let btcLong = PerplLivePosition(pid: 10, marketId: 1, isLong: true, sizeRaw: 10000, statusRaw: 1)

        // Holding a BTC long: its own triggers stay; the short-side one and ETH's (no ETH position) are orphans.
        XCTAssertEqual(PerplTriggerCleanup.orphans(orders: orders, positions: [btcLong]).map(\.oid), [3, 4])
        // A resting ETH entry may be what the ETH trigger waits on.
        let ethEntry = order(oid: 5, market: 20, type: 1, tp: nil, tpc: nil)
        XCTAssertTrue(ethEntry.isRestingEntry)
        XCTAssertEqual(PerplTriggerCleanup.orphans(orders: orders + [ethEntry], positions: [btcLong]).map(\.oid), [3])
        XCTAssertEqual(PerplTriggerCleanup.orphans(orders: orders, positions: [btcLong], extraRestingEntries: [PerplMarketSide(marketId: 20, isLong: true)]).map(\.oid), [3])
        XCTAssertEqual(PerplTriggerCleanup.orphans(orders: orders, positions: [btcLong], extraRestingEntries: [PerplMarketSide(marketId: 20, isLong: false)]).map(\.oid), [3, 4],
                       "an entry sent on the other side says nothing about the long's triggers")

        // The BTC long closed: its take-profit and stop-loss are the siblings to cancel — not the short-side one.
        let closed = PerplLivePosition(pid: 10, marketId: 1, isLong: true, sizeRaw: 0, statusRaw: 2)
        XCTAssertEqual(PerplTriggerCleanup.siblings(of: closed, orders: orders, positions: []).map(\.oid), [1, 2])
        // ...unless a new long on BTC is already open, or an entry is resting there.
        let reopened = PerplLivePosition(pid: 11, marketId: 1, isLong: true, sizeRaw: 5000, statusRaw: 1)
        XCTAssertTrue(PerplTriggerCleanup.siblings(of: closed, orders: orders, positions: [reopened]).isEmpty)
        XCTAssertTrue(PerplTriggerCleanup.siblings(of: closed, orders: orders + [order(oid: 6, type: 1, tp: nil, tpc: nil)], positions: []).isEmpty)
        // A trigger that already fired is the keeper's to finish.
        let firing = PerplOpenOrder(oid: 7, marketId: 1, typeRaw: 3, statusRaw: 9, priceRaw: 0, sizeRaw: 10000, filledRaw: 0,
                                    triggerPriceRaw: 900000, triggerConditionRaw: 4, linkedPositionId: nil, leverageHundredths: 0)
        XCTAssertEqual(PerplTriggerCleanup.siblings(of: closed, orders: [firing, longSL], positions: []).map(\.oid), [1])
    }

    // MARK: Security audit review (GT-1, GT-2, GT-3, GT-6, GT-9)

    func testRestingEntryExemptsOnlyItsOwnSide() {
        let longSL = order(oid: 1, type: 3)                              // CloseLong stop on BTC, no BTC long open
        let restingShort = order(oid: 2, type: 2, tp: nil, tpc: nil)     // a far-away limit short on BTC
        let restingLong = order(oid: 3, type: 1, tp: nil, tpc: nil)      // a limit long on BTC
        XCTAssertEqual(restingShort.side, PerplMarketSide(marketId: 1, isLong: false))
        XCTAssertEqual(longSL.side, PerplMarketSide(marketId: 1, isLong: true))
        XCTAssertEqual(PerplTriggerCleanup.orphans(orders: [longSL, restingShort], positions: []).map(\.oid), [1],
                       "a resting short never hides the orphaned stop-loss of a long")
        XCTAssertTrue(PerplTriggerCleanup.orphans(orders: [longSL, restingLong], positions: []).isEmpty, "it may be waiting on the resting long")
    }

    func testTheSameOrderIdOnTwoMarketsIsTwoOrders() {
        let c = client()
        var events: [PerplTriggerEvent] = []
        c.onTriggerEvent = { events.append($0) }
        // BTC's trigger 12 and ETH's resting entry 12: both kept.
        let ethEntry: [String: Any] = ["oid": 12, "mkt": 20, "t": 1, "st": 2, "p": 30000000, "os": 100, "fs": 0, "lv": 500]
        c.handle(frame(["mt": 23, "d": [trigger(oid: 12, st: 8), ethEntry]]))
        XCTAssertEqual(Set(c.openOrders.map(\.id)), [PerplOpenOrder.Key(marketId: 1, oid: 12), PerplOpenOrder.Key(marketId: 20, oid: 12)])
        // ETH's order fills: BTC's trigger is untouched, and nothing is announced for it.
        c.handle(frame(["mt": 24, "d": [["oid": 12, "mkt": 20, "st": 4, "fs": 100, "r": true]]]))
        XCTAssertEqual(c.openOrders.map(\.id), [PerplOpenOrder.Key(marketId: 1, oid: 12)])
        XCTAssertEqual(c.openOrders.first?.triggerPriceRaw, 900000)
        XCTAssertTrue(events.isEmpty)
        // An ETH trigger with the same id: its own order, and its firing is its own event.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 12, st: 8, market: 20)]]))
        XCTAssertEqual(c.openOrders.count, 2)
        // An update with no market can't be told apart while two orders share the id: ignored, not merged into either.
        c.handle(frame(["mt": 24, "d": [["oid": 12, "st": 9, "sr": 54]]]))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(c.openOrders.map(\.statusRaw), [8, 8])
        c.handle(frame(["mt": 24, "d": [trigger(oid: 12, st: 9, sr: 54)]]))
        c.handle(frame(["mt": 24, "d": [trigger(oid: 12, st: 9, sr: 54, market: 20)]]))
        XCTAssertEqual(events.map(\.order.marketId), [1, 20], "one trigger firing never hides the other market's")
        // With one order left for the id, an update without a market is that order's.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 12, st: 10, sr: 65, removed: true, market: 20)]]))
        c.handle(frame(["mt": 24, "d": [["oid": 12, "st": 10, "sr": 65, "r": true]]]))
        XCTAssertTrue(c.openOrders.isEmpty)
    }

    func testALateDuplicateFailureKeepsTheLiveTrigger() {
        let c = client()
        var events: [PerplTriggerEvent] = []
        c.onTriggerEvent = { events.append($0) }
        c.handle(frame(["mt": 23, "d": [trigger(oid: 5, st: 8)]]))
        // The late failure of a resent request (request id too low): Perpl's first non-failure status stands.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 5, st: 7, sr: 32)]]))
        XCTAssertEqual(c.openOrders.map(\.oid), [5])
        XCTAssertEqual(c.openOrders.first?.statusRaw, 8)
        XCTAssertTrue(events.isEmpty)
        // A real outcome after it still counts: it fired and couldn't be carried out.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 5, st: 7, sr: 64, removed: true)]]))
        XCTAssertEqual(events.map(\.outcome), [.failed(reason: 64)])
        XCTAssertTrue(c.openOrders.isEmpty)
        // A failure for an order never admitted is its answer, whatever the reason.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 6, st: 7, sr: 32)]]))
        XCTAssertEqual(events.last?.outcome, .failed(reason: 32))
    }

    func testATriggeredOrderThatExpiresIsReportedAsFailed() {
        let c = client()
        var events: [PerplTriggerEvent] = []
        c.onTriggerEvent = { events.append($0) }
        c.handle(frame(["mt": 23, "d": [trigger(oid: 5, st: 8), trigger(oid: 6, st: 8)]]))
        c.handle(frame(["mt": 24, "d": [trigger(oid: 5, st: 9, sr: 54)]]))
        c.handle(frame(["mt": 24, "d": [trigger(oid: 5, st: 6, sr: 67, removed: true)]]))
        XCTAssertEqual(events.map(\.outcome), [.triggered, .failed(reason: 67)], "told it was closing, then that it couldn't")
        // One that expires without firing no longer protects anything either.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 6, st: 6, sr: 6, removed: true)]]))
        XCTAssertEqual(events.last?.outcome, .expired)
        XCTAssertTrue(c.openOrders.isEmpty)
    }

    func testTriggerOutcomes() {
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 9, reason: 68), .triggered, "a recoverable failure is still being retried")
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 7, reason: 68), .failed(reason: 68))
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 6, reason: 68), .failed(reason: 67))
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 6, reason: 67), .failed(reason: 67))
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 5, reason: 67), .failed(reason: 67))
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 6, reason: 0), .expired)
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 10, reason: 65), .triggered)
        XCTAssertNil(PerplTradeClient.triggerOutcome(status: 5, reason: 28), "cancelled")
        XCTAssertNil(PerplTradeClient.triggerOutcome(status: 8, reason: 0))
    }

    // MARK: Request ids, outcomes and the stream's own reports (frame replay)

    /// The frames written, as the socket would carry them.
    private final class Wire {
        var frames: [[String: Any]] = []
        var requestIds: [Int] { frames.compactMap { $0["rq"] as? Int } }
    }

    /// Signs `c` in on a test transport: WalletSnapshot `sn`, account 10 with `lfr`, one-click on.
    @discardableResult
    private func signIn(_ c: PerplTradeClient, lfr: Int = 5, sn: Int = 9, account: [String: Any] = [:]) -> Wire {
        let wire = Wire()
        c.transport = { text in
            wire.frames.append((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:])
        }
        var fields: [String: Any] = ["id": 10, "lfr": lfr, "fw": true]
        fields.merge(account) { $1 }
        c.handle(frame(["mt": 19, "sn": sn, "as": [fields]]))
        return wire
    }

    private func ack(_ c: PerplTradeClient, sn: Int, code: Int = 0) {
        c.handle(frame(["mt": 3, "cid": sn, "status": ["code": code]]))
    }

    /// Lets the tasks started by a test run until `condition` holds (or a generous bound passes).
    private func until(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 2_000 {
            spins += 1
            await Task.yield()
        }
    }

    private func sentEntry(_ size: Int = 100, ioc: Bool = true) -> PerplSentRequest {
        PerplSentRequest(accountId: 10, marketId: 1, wireType: 1, lotLNS: size, kind: .entry(ioc: ioc, sizeRaw: size), writtenAt: Date())
    }

    private func cancelFrame(oid: Int = 3) -> PerplOrderFrame { PerplOrders.cancel(perpId: 1, orderId: oid, accountId: 10, head: 0) }

    func testRequestIdsRiseInWriteOrder() async throws {
        let c = client()
        let wire = signIn(c)
        let market = btc()
        var entry = PerplOrders.entry(OrderInput(market: market, side: .long, kind: .market, size: 0.1, leverage: 5), accountId: 10, head: 0)
        var tp = PerplOrders.takeProfit(side: .long, price: 100000, size: 0.1, market: market, accountId: 10, linkedPositionId: nil)
        var sl = PerplOrders.stopLoss(side: .long, price: 90000, size: 0.1, market: market, accountId: 10, linkedPositionId: nil)
        let reserved = c.reserveRequestId()
        XCTAssertEqual(reserved, 6)
        entry.requestId = reserved
        tp.linkedRequestId = reserved
        sl.linkedRequestId = reserved
        let bracket = Task { try await c.placeAll([entry, tp, sl]) }
        await until { wire.frames.count == 1 }
        // A cancel goes out while the entry waits for its ack: it takes the next id, and the triggers come after it.
        let cancel = Task { try await c.sendEach([cancelFrame()]) }
        await until { wire.frames.count == 2 }
        ack(c, sn: 1)
        await until { wire.frames.count == 3 }
        ack(c, sn: 2)
        ack(c, sn: 3)
        await until { wire.frames.count == 4 }
        ack(c, sn: 4)
        let acks = try await bracket.value
        let cancelAcks = try await cancel.value
        XCTAssertEqual(wire.requestIds, [6, 7, 8, 9], "strictly increasing in write order")
        XCTAssertEqual(wire.frames.map { $0["t"] as? Int }, [1, 5, 3, 3])
        XCTAssertEqual(wire.frames.compactMap { $0["tr"] as? Int }, [6, 6], "both triggers link to the entry")
        XCTAssertEqual(acks.map(\.requestId), [6, 8, 9])
        XCTAssertEqual(cancelAcks.map(\.requestId), [7])
        XCTAssertTrue((acks + cancelAcks).allSatisfy(\.accepted))
        XCTAssertEqual(c.sentRequest(rq: 7)?.kind, .cancel)
        XCTAssertEqual(c.sentRequest(rq: 8)?.kind, .trigger)
        XCTAssertEqual(c.sentRequest(rq: 6)?.kind, .entry(ioc: true, sizeRaw: 10000))
    }

    func testAReservationOvertakenByAnotherWriteIsNeverSent() async throws {
        let c = client()
        let wire = signIn(c)
        let reserved = c.reserveRequestId()
        let cancel = Task { try await c.sendEach([cancelFrame()]) }
        await until { wire.frames.count == 1 }
        XCTAssertEqual(wire.requestIds, [7])
        var entry = PerplOrders.entry(OrderInput(market: btc(), side: .long, kind: .market, size: 0.1, leverage: 5), accountId: 10, head: 0)
        entry.requestId = reserved
        do {
            _ = try await c.placeAll([entry])
            XCTFail("an id below one already written must never go out")
        } catch let error as PerplTradeError {
            guard case .unavailable(let why) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(why, "Another request went out first, so this one wasn't sent. Nothing was placed. Try again.")
            XCTAssertFalse(error.outcomeUnknown, "nothing was sent: the caller refunds")
        }
        XCTAssertEqual(wire.requestIds, [7], "nothing written for 6")
        ack(c, sn: 1)
        _ = try await cancel.value
    }

    func testAnUnansweredFrameStillReportsItsRequestId() async throws {
        let c = client()
        let wire = signIn(c)
        let cancel = Task { try await c.sendEach([cancelFrame()]) }
        await until { wire.frames.count == 1 }
        c.disconnect()
        let acks = try await cancel.value
        XCTAssertEqual(acks.first?.requestId, 6)
        XCTAssertEqual(acks.first?.outcomeUnknown, true)
    }

    func testAWaiterResolvesFromTheStream() async {
        let c = client()
        signIn(c, account: ["b": "1000000", "lb": "0"])
        XCTAssertEqual(c.balanceCNS, 1_000_000)
        XCTAssertEqual(c.lockedBalanceCNS, 0)
        let sent = sentEntry()
        let waiting = Task { await c.awaitOutcome(rq: 6, sent: sent, deadline: PerplOutcomeDeadline(ackHead: nil, ttlBlocks: 20, ackAt: Date())) }
        await until { c.hasRequestsInFlight }
        XCTAssertTrue(c.hasRequestsInFlight, "the drain holds the socket for an outcome being waited for")
        c.handle(frame(["mt": 24, "d": [["rq": 6, "mkt": 1, "oid": 77, "st": 4, "fs": 100, "fp": 816155, "f": "345", "at": ["b": 1, "txid": "ab"]]]]))
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .filled(PerplFillSummary(filledSizeRaw: 100, requestedSizeRaw: 100, priceRaw: 816155, feeCNS: "345", txid: "0xab")))
        XCTAssertFalse(c.hasRequestsInFlight)
        XCTAssertTrue(c.openOrders.isEmpty, "a filled entry is still never listed")
        XCTAssertEqual(c.lastTerminalStatus(of: PerplOpenOrder.Key(marketId: 1, oid: 77))?.status, 4)
        // A balance that isn't a whole number is unknown, never a guess.
        c.handle(frame(["mt": 21, "id": 10, "b": "1.5"]))
        XCTAssertNil(c.balanceCNS)
    }

    func testAFailureWithoutAnOrderIdIsNotLost() {
        let c = client()
        signIn(c)
        var events: [PerplTriggerEvent] = []
        c.onTriggerEvent = { events.append($0) }
        c.handle(frame(["mt": 24, "d": [["rq": 7, "mkt": 1, "st": 7, "sr": 34]]]))
        XCTAssertEqual(c.outcome(rq: 7, sent: sentEntry(), final: false), .failed(PerplOrderReason(status: 7, reason: 34)))
        XCTAssertTrue(c.openOrders.isEmpty)
        XCTAssertTrue(events.isEmpty)
    }

    func testAWaiterIsReleasedWhenTheSocketClosesAndTimesOut() async {
        let c = client()
        signIn(c)
        let waiting = Task { await c.awaitOutcome(rq: 8, sent: self.sentEntry(), deadline: PerplOutcomeDeadline(ackHead: nil, ttlBlocks: 20, ackAt: Date())) }
        await until { c.hasRequestsInFlight }
        c.disconnect()
        let released = await waiting.value
        XCTAssertEqual(released, .unconfirmed(.connectionLost))
        XCTAssertFalse(c.hasRequestsInFlight)
        // Not signed in: nothing to wait on.
        let closed = await c.awaitOutcome(rq: 9, sent: sentEntry(), deadline: PerplOutcomeDeadline(ackHead: nil, ttlBlocks: 20, ackAt: Date()))
        XCTAssertEqual(closed, .unconfirmed(.connectionLost))

        let quiet = client()
        signIn(quiet)
        let timedOut = await quiet.awaitOutcome(rq: 9, sent: sentEntry(), deadline: PerplOutcomeDeadline(ackHead: nil, ttlBlocks: nil, ackAt: Date(), cap: 0.05))
        XCTAssertEqual(timedOut, .unconfirmed(.timedOut))
        XCTAssertFalse(quiet.hasRequestsInFlight)
    }

    func testAProvisionalFailureNeverEndsTheWaitEarly() async {
        let c = client()
        signIn(c)
        let sent = sentEntry()
        let waiting = Task { await c.awaitOutcome(rq: 6, sent: sent, deadline: PerplOutcomeDeadline(ackHead: nil, ttlBlocks: nil, ackAt: Date(), cap: 0.2)) }
        await until { c.hasRequestsInFlight }
        c.handle(frame(["mt": 24, "d": [["rq": 6, "mkt": 1, "st": 7, "sr": 1]]]))
        XCTAssertTrue(c.hasRequestsInFlight, "a provisional failure is not the answer yet")
        XCTAssertEqual(c.provisionalFailure(rq: 6, accountId: 10), PerplOrderReason(status: 7, reason: 1))
        XCTAssertTrue(c.continuityHeld(since: sent.writtenAt))
        let final = await waiting.value
        XCTAssertEqual(final, .failed(PerplOrderReason(status: 7, reason: 1)), "the deadline passed with the socket signed in throughout")

        // Without continuity (the socket closed first) it stays unconfirmed: the caller reconciles.
        let dropped = client()
        signIn(dropped)
        let sentAgain = sentEntry()
        let lost = Task { await dropped.awaitOutcome(rq: 6, sent: sentAgain, deadline: PerplOutcomeDeadline(ackHead: nil, ttlBlocks: nil, ackAt: Date(), cap: 5)) }
        await until { dropped.hasRequestsInFlight }
        dropped.handle(frame(["mt": 24, "d": [["rq": 6, "mkt": 1, "st": 7, "sr": 1]]]))
        dropped.disconnect()
        let outcome = await lost.value
        XCTAssertEqual(outcome, .unconfirmed(.connectionLost))
        XCTAssertFalse(dropped.continuityHeld(since: sentAgain.writtenAt))
    }

    func testHeartbeatsOnTheTradingSocket() async {
        let c = client()
        signIn(c, sn: 9)
        var beats: [PerplHeartbeat.Beat] = []
        c.onHeartbeat = { beats.append($0) }
        c.handle(frame(["mt": 100, "sn": 10, "h": 500]))
        XCTAssertEqual(c.heartbeat.head, 500)
        XCTAssertEqual(c.heartbeat.gaps, 0)
        XCTAssertFalse(c.streamSuspect)
        c.handle(frame(["mt": 100, "sn": 13, "h": 503]))
        XCTAssertEqual(c.heartbeat.gaps, 1)
        XCTAssertTrue(c.streamSuspect, "updates may have been missed")
        XCTAssertTrue(c.signedIn, "log-only: a gap never closes the socket")
        XCTAssertEqual(beats, [.gap(missed: 2)], "only beats that aren't in order are reported")
        XCTAssertEqual(PerplOutcomeDeadline(ackHead: c.heartbeat.head, ttlBlocks: 20, ackAt: Date()).block, 528)
        // A block deadline ends a wait on the heartbeat that reaches it.
        let waiting = Task { await c.awaitOutcome(rq: 6, sent: self.sentEntry(), deadline: PerplOutcomeDeadline(ackHead: 500, ttlBlocks: 20, ackAt: Date())) }
        await until { c.hasRequestsInFlight }
        c.handle(frame(["mt": 100, "sn": 14, "h": 525]))
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .unconfirmed(.timedOut))
        let census = c.drainCensus()
        XCTAssertEqual(census.heartbeatsInOrder, 2)
        XCTAssertEqual(census.heartbeatGaps, 1)
        XCTAssertEqual(census.firstBeatContinuedSnapshot, 1)
        XCTAssertEqual(census.outcomesTimedOut, 1)
        XCTAssertEqual(c.drainCensus(), PerplStreamCensus(), "handed over once")
    }

    func testANewClientNeverReusesARequestId() async throws {
        let store = PerplRequestIdStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let first = client()
        first.onRequestIdIssued = { store.record($0, chainId: 143, accountId: 10) }
        let wire = signIn(first, lfr: 5)
        let cancel = Task { try await first.sendEach([self.cancelFrame()]) }
        await until { wire.frames.count == 1 }
        XCTAssertEqual(wire.requestIds, [6])
        XCTAssertEqual(store.highWater(chainId: 143, accountId: 10), 6)
        first.disconnect()
        _ = try await cancel.value
        // The next socket's snapshot still says lfr 5 (Perpl hasn't forwarded 6 yet): it starts above 6 all the same.
        let second = client()
        second.onAccountUpdate = { [weak second] in
            guard let second, let id = second.accountId else { return }
            second.seedRequestIds(atLeast: store.highWater(chainId: 143, accountId: id))
        }
        signIn(second, lfr: 5)
        XCTAssertEqual(second.reserveRequestId(), 7)
    }

    func testPostOnlyRidesTheFrame() {
        let market = btc()
        let postOnly = PerplOrders.entry(OrderInput(market: market, side: .long, kind: .limit, size: 0.1, price: 90000, leverage: 5, postOnly: true), accountId: 1, head: 0)
        XCTAssertTrue(postOnly.postOnly)
        XCTAssertEqual(postOnly.json(rq: 1, sn: 1)["fl"] as? Int, 1)
        let plain = PerplOrders.entry(OrderInput(market: market, side: .long, kind: .limit, size: 0.1, price: 90000, leverage: 5), accountId: 1, head: 0)
        XCTAssertEqual(plain.json(rq: 1, sn: 1)["fl"] as? Int, 0)
        let marketOrder = PerplOrders.entry(OrderInput(market: market, side: .long, kind: .market, size: 0.1, leverage: 5, postOnly: true), accountId: 1, head: 0)
        XCTAssertFalse(marketOrder.postOnly, "post-only applies to limits only")
        XCTAssertEqual(marketOrder.json(rq: 1, sn: 1)["fl"] as? Int, 4)
        XCTAssertEqual(PerplOrders.takeProfit(side: .long, price: 100000, size: 0.1, market: market, accountId: 1, linkedPositionId: nil).json(rq: 1, sn: 1)["fl"] as? Int, 4)
        XCTAssertEqual(postOnly.json(rq: 1, sn: 1)["lb"] as? Int, 0, "lb: 0 on every frame")
    }

    func testPositionUpdatesCarryTheirDetails() {
        let c = client()
        signIn(c)
        var completed = 0
        c.onSnapshotsComplete = { completed += 1 }
        c.handle(frame(["mt": 26, "d": [[String: Any]]()]))
        XCTAssertEqual(completed, 0, "not until both snapshots are in")
        c.handle(frame(["mt": 23, "d": [[String: Any]]()]))
        XCTAssertEqual(completed, 1)
        c.handle(frame(["mt": 27, "d": [["pid": 41, "mkt": 1, "sd": 1, "s": 20000, "st": 1, "ep": 816155, "c": "50000000", "lv": 500, "rq": 6, "oid": 77, "sr": 0]]]))
        var position = c.positions.first
        XCTAssertEqual(position?.entryPriceRaw, 816155)
        XCTAssertEqual(position?.collateralCNS, "50000000")
        XCTAssertEqual(position?.leverageHundredths, 500)
        XCTAssertEqual(position?.requestId, 6)
        XCTAssertEqual(position?.orderId, 77)
        c.handle(frame(["mt": 27, "d": [["pid": 41, "s": 30000]]]))
        position = c.positions.first
        XCTAssertEqual(position?.sizeRaw, 30000)
        XCTAssertEqual(position?.entryPriceRaw, 816155, "a partial update keeps what it didn't carry")
        XCTAssertEqual(position?.requestId, 6)
        c.handle(frame(["mt": 23, "d": [[String: Any]]()]))
        XCTAssertEqual(completed, 1, "once per socket")
    }

    func testAnotherAccountsUpdateNeverOverwritesThisOne() {
        let c = client()
        signIn(c, lfr: 5)
        c.handle(frame(["mt": 21, "id": 11, "fw": false, "lfr": 900, "b": "7"]))
        XCTAssertEqual(c.accountId, 10)
        XCTAssertTrue(c.forwardingEnabled)
        XCTAssertNil(c.balanceCNS)
        XCTAssertEqual(c.reserveRequestId(), 6, "lfr 900 was another account's")
        c.handle(frame(["mt": 21, "id": 10, "b": "2500000"]))
        XCTAssertEqual(c.balanceCNS, 2_500_000)
        XCTAssertEqual(c.drainCensus().otherAccountUpdates, 1)
    }

    func testACancelRequestsOwnReportNeverRewritesItsTarget() async throws {
        let c = client()
        let wire = signIn(c)
        var events: [PerplTriggerEvent] = []
        c.onTriggerEvent = { events.append($0) }
        c.handle(frame(["mt": 23, "d": [trigger(oid: 5, st: 8)]]))
        let key = PerplOpenOrder.Key(marketId: 1, oid: 5)
        // Its own pending report names the target's id: the target keeps its own type and trigger.
        c.handle(frame(["mt": 24, "d": [["rq": 9, "mkt": 1, "oid": 5, "t": 5, "st": 1]]]))
        XCTAssertEqual(c.openOrders.first?.typeRaw, 3)
        XCTAssertEqual(c.openOrders.first?.triggerPriceRaw, 900000)
        // Refused: the target stays listed, and the refusal is the cancel's, not a failed trigger.
        c.handle(frame(["mt": 24, "d": [["rq": 9, "mkt": 1, "oid": 5, "t": 5, "st": 7, "sr": 45]]]))
        XCTAssertEqual(c.openOrders.map(\.id), [key])
        XCTAssertEqual(c.outcome(rq: 9, sent: PerplSentRequest(accountId: 10, marketId: 1, wireType: 5, lotLNS: 0, kind: .cancel, writtenAt: Date()), final: false),
                       .failed(PerplOrderReason(status: 7, reason: 45)))
        XCTAssertTrue(events.isEmpty)
        // One that went through removes it, as cancelled — never as fired.
        c.handle(frame(["mt": 24, "d": [["rq": 10, "mkt": 1, "oid": 5, "t": 5, "st": 4]]]))
        XCTAssertTrue(c.openOrders.isEmpty)
        XCTAssertEqual(c.lastTerminalStatus(of: key)?.status, 5)
        XCTAssertEqual(c.lastTerminalStatus(of: key)?.reason, 28)
        XCTAssertTrue(events.isEmpty)
        // The target's own reports.
        c.handle(frame(["mt": 23, "d": [trigger(oid: 5, st: 8), trigger(oid: 6, st: 8)]]))
        c.handle(frame(["mt": 24, "d": [["oid": 5, "mkt": 1, "st": 5, "sr": 28, "r": true]]]))
        XCTAssertEqual(c.lastTerminalStatus(of: key)?.status, 5)
        c.handle(frame(["mt": 24, "d": [["oid": 6, "st": 10, "sr": 65, "r": true]]]))
        XCTAssertEqual(c.lastTerminalStatus(of: PerplOpenOrder.Key(marketId: 1, oid: 6))?.status, 10)
        XCTAssertEqual(c.lastTerminalStatus(of: PerplOpenOrder.Key(marketId: 1, oid: 6))?.reason, 65)
        XCTAssertEqual(events.map(\.outcome), [.triggered], "only the trigger that fired")

        // A partial update of a cancel this socket wrote may leave out `t`: still the cancel's own.
        c.handle(frame(["mt": 23, "d": [trigger(oid: 7, st: 8)]]))
        let cancel = Task { try await c.sendEach([self.cancelFrame(oid: 7)]) }
        await until { wire.frames.count == 1 }
        let written = try XCTUnwrap(wire.requestIds.first)
        c.handle(frame(["mt": 24, "d": [["rq": written, "mkt": 1, "oid": 7, "st": 1]]]))
        XCTAssertEqual(c.openOrders.first?.typeRaw, 3)
        XCTAssertEqual(c.openOrders.first?.statusRaw, 8)
        ack(c, sn: 1)
        _ = try await cancel.value
        let census = c.drainCensus()
        XCTAssertEqual(census.cancelOwnEvents, 1, "counted once per cancel this socket wrote")
    }

    /// A cancel is confirmed only by the list of the socket that wrote it, signed in with its orders snapshot (real-time
    /// spec §5.4, I9): its order left as cancelled, triggered or expired first, or was already gone; or the cancel was
    /// refused while it is still listed; or nothing can be said yet. Another socket's list, or one a close emptied, says
    /// nothing about it.
    func testACancelIsConfirmedOnlyOnTheSocketThatSentIt() async throws {
        let c = client()
        let wire = signIn(c)
        c.handle(frame(["mt": 23, "d": [4, 5, 6, 7, 8].map { trigger(oid: $0, st: 8) }]))
        let oids = [4, 5, 6, 7, 8, 9]
        let cancels = Task { try await c.sendEach(oids.map { self.cancelFrame(oid: $0) }) }
        for sn in 1...oids.count {
            await until { wire.frames.count == sn }
            ack(c, sn: sn)
        }
        let acks = try await cancels.value
        var rq: [Int: Int] = [:]
        for (oid, ack) in zip(oids, acks) { rq[oid] = try XCTUnwrap(ack.requestId) }
        func key(_ oid: Int) -> PerplOpenOrder.Key { PerplOpenOrder.Key(marketId: 1, oid: oid) }
        func result(_ oid: Int, on socket: PerplTradeClient? = nil) -> PerplCancelResult? { (socket ?? c).cancelResult(of: key(oid), cancelRq: rq[oid] ?? 0) }

        XCTAssertNil(result(5), "still listed and nothing said: still waiting")
        XCTAssertEqual(result(9), .alreadyGone, "not on the list when its cancel went out")
        // The cancel's own reports: refused (the order stays listed), or through (the order leaves, as cancelled).
        c.handle(frame(["mt": 24, "d": [["rq": rq[5] ?? 0, "mkt": 1, "oid": 5, "t": 5, "st": 7, "sr": 45]]]))
        XCTAssertEqual(c.openOrders.map(\.oid), [4, 5, 6, 7, 8])
        XCTAssertEqual(result(5), .refused("Perpl couldn't cancel it."))
        c.handle(frame(["mt": 24, "d": [["rq": rq[4] ?? 0, "mkt": 1, "oid": 4, "t": 5, "st": 4]]]))
        XCTAssertEqual(result(4), .cancelled)
        // The orders' own reports.
        c.handle(frame(["mt": 24, "d": [["oid": 6, "mkt": 1, "st": 5, "sr": 28, "r": true], ["oid": 7, "mkt": 1, "st": 10, "sr": 65, "r": true],
                                        ["oid": 8, "mkt": 1, "st": 6, "r": true]]]))
        XCTAssertEqual(result(6), .cancelled)
        XCTAssertEqual(result(7), .firedFirst)
        XCTAssertEqual(result(8), .expiredFirst)
        XCTAssertEqual(c.openOrders.map(\.oid), [5])

        // Another socket didn't write that cancel: its list says nothing about it, even with the order gone from it.
        let other = client()
        signIn(other)
        other.handle(frame(["mt": 23, "d": [[String: Any]]()]))
        XCTAssertNil(result(6, on: other))
        // A list the socket's close emptied proves nothing either.
        c.disconnect()
        XCTAssertNil(result(6))
        XCTAssertNil(result(9))
    }

    /// How an order that left the live list left it, by the status it left with.
    func testHowAnOrderLeftTheList() {
        XCTAssertEqual(PerplCancelResult.left(withStatus: 5), .cancelled)
        XCTAssertEqual(PerplCancelResult.left(withStatus: 8), .cancelled, "an r: true that kept its live status")
        for status in [4, 9, 10] { XCTAssertEqual(PerplCancelResult.left(withStatus: status), .firedFirst) }
        XCTAssertEqual(PerplCancelResult.left(withStatus: 6), .expiredFirst)
        XCTAssertEqual(PerplCancelResult.left(withStatus: 7), .alreadyGone, "it failed on its own")
        XCTAssertTrue([PerplCancelResult.cancelled, .firedFirst, .expiredFirst, .alreadyGone].allSatisfy(\.isGone))
        XCTAssertFalse(PerplCancelResult.refused("x").isGone)
        XCTAssertFalse(PerplCancelResult.notConfirmed.isGone)
    }

    /// A new take-profit / stop-loss settles on the stream (real-time spec §5.4): armed once Perpl lists it untriggered;
    /// a refusal that isn't final at once only when the wait ends with the socket signed in throughout.
    func testANewTriggerIsArmedOrRefusedOnTheStream() async {
        let c = client()
        signIn(c)
        let sent = PerplSentRequest(accountId: 10, marketId: 1, wireType: 3, lotLNS: 10000, kind: .trigger, writtenAt: Date())
        c.handle(frame(["mt": 24, "d": [["rq": 12, "mkt": 1, "oid": 40, "t": 3, "st": 8, "tp": 900000, "tpc": 4]]]))
        XCTAssertEqual(c.outcome(rq: 12, sent: sent, final: false), .armed)
        XCTAssertEqual(c.openOrders.map(\.oid), [40])
        c.handle(frame(["mt": 24, "d": [["rq": 13, "st": 7, "sr": 24]]]))
        XCTAssertNil(c.outcome(rq: 13, sent: sent, final: false), "not final until the wait ends")
        let answers = await c.awaitOutcomes([12: sent, 13: sent], cap: 0.2)
        XCTAssertEqual(answers[12], .armed)
        XCTAssertEqual(answers[13], .failed(PerplOrderReason(status: 7, reason: 24)), "the cap passed with the socket signed in throughout")
        XCTAssertEqual(PerplOrderReason(status: 7, reason: 24).message, "Your account has the most open orders Perpl allows. Cancel some first.")
        XCTAssertFalse(c.hasRequestsInFlight)
    }

    func testAnOrderThatOnlyReducesTheOtherSideTakesNoTriggers() {
        // Holding 1 BTC long: a 0.3 short only shrinks it; a 1.3 short turns it into a 0.3 short.
        XCTAssertTrue(PerplTriggerRules.onlyReduces(side: .short, size: 0.3, positionSide: .long, positionSize: 1))
        XCTAssertTrue(PerplTriggerRules.onlyReduces(side: .short, size: 1, positionSide: .long, positionSize: 1), "closes it exactly")
        XCTAssertFalse(PerplTriggerRules.onlyReduces(side: .short, size: 1.3, positionSide: .long, positionSize: 1))
        XCTAssertFalse(PerplTriggerRules.onlyReduces(side: .long, size: 0.3, positionSide: .long, positionSize: 1), "adds to it")
        XCTAssertFalse(PerplTriggerRules.onlyReduces(side: .short, size: 0.3, positionSide: nil, positionSize: 0))
        XCTAssertEqual(PerplTriggerRules.Problem.reducesPosition(.long).message(market: btc()),
                       "This order only reduces your long, so its take-profit and stop-loss would have no short to close and would stay armed for your next short here. Set them with TP/SL on the position instead.")
    }

    // MARK: Close, cancel and add margin over the trading connection (p4 spec A)

    private func listed(oid: Int, scid: Int?, type: Int = 1, price: Int = 780000, market: Int = 1, tp: Int? = nil) -> PerplOpenOrder {
        PerplOpenOrder(oid: oid, marketId: market, typeRaw: type, statusRaw: 2, priceRaw: price, sizeRaw: 100, filledRaw: 0, triggerPriceRaw: tp,
                       triggerConditionRaw: tp == nil ? nil : 4, linkedPositionId: nil, leverageHundredths: 500, contractOrderId: scid)
    }

    /// The stream's order for an on-chain resting order is found by Perpl's smart contract order id only, and only when
    /// every term matches: else the cancel stays a wallet transaction.
    func testTheStreamOrderOfAChainOrderMatchesByItsContractId() {
        let chain = PerpOrder(perpId: 1, orderId: 31, symbol: "BTC", type: .openLong, side: .buy, price: 78000, size: 0.001, leverage: 5, expiryBlock: 0, reduceOnly: false)
        XCTAssertEqual(PerplOpenOrder.streamOrder(for: chain, in: [listed(oid: 31, scid: 31)], priceDecimals: 1)?.oid, 31)
        XCTAssertEqual(PerplOpenOrder.streamOrder(for: chain, in: [listed(oid: 77, scid: 31)], priceDecimals: 1)?.oid, 77, "by scid, never by oid")
        XCTAssertNil(PerplOpenOrder.streamOrder(for: chain, in: [listed(oid: 31, scid: nil)], priceDecimals: 1), "no scid")
        XCTAssertNil(PerplOpenOrder.streamOrder(for: chain, in: [listed(oid: 31, scid: 31, type: 2)], priceDecimals: 1), "another type")
        XCTAssertNil(PerplOpenOrder.streamOrder(for: chain, in: [listed(oid: 31, scid: 31, price: 780001)], priceDecimals: 1), "another price")
        XCTAssertNil(PerplOpenOrder.streamOrder(for: chain, in: [listed(oid: 31, scid: 31, market: 2)], priceDecimals: 1), "another market")
        XCTAssertNil(PerplOpenOrder.streamOrder(for: chain, in: [listed(oid: 31, scid: 31, tp: 750000)], priceDecimals: 1), "a trigger")
        XCTAssertNil(PerplOpenOrder.streamOrder(for: chain, in: [listed(oid: 31, scid: 31), listed(oid: 32, scid: 31)], priceDecimals: 1), "two matches")
        XCTAssertNil(PerplOpenOrder.streamOrder(for: chain, in: [], priceDecimals: 1))
    }

    /// The smart contract order id rides each order (a partial update keeps it), and how the order left the list is kept by
    /// it too: what tells an on-chain order's card it is gone.
    func testTheContractOrderIdAndHowTheOrderLeft() {
        let c = client()
        signIn(c)
        c.handle(frame(["mt": 23, "d": [["oid": 31, "scid": 31, "rq": 480, "mkt": 1, "t": 1, "st": 2, "p": 780000, "os": 100, "fs": 0, "lv": 500]]]))
        XCTAssertEqual(c.openOrders.first?.contractOrderId, 31)
        c.handle(frame(["mt": 24, "d": [["oid": 31, "mkt": 1, "fs": 40, "st": 3]]]))
        XCTAssertEqual(c.openOrders.first?.contractOrderId, 31, "a partial update keeps it")
        XCTAssertNil(c.lastTerminalStatus(marketId: 1, contractOrderId: 31))
        c.handle(frame(["mt": 24, "d": [["oid": 31, "mkt": 1, "st": 4, "fs": 100, "r": true]]]))
        XCTAssertTrue(c.openOrders.isEmpty)
        XCTAssertEqual(c.lastTerminalStatus(marketId: 1, contractOrderId: 31)?.status, 4)
        // When it was seen: the Exchange gives the id again, so the app weighs how recent the record is.
        XCTAssertLessThan(abs(c.lastTerminalStatus(marketId: 1, contractOrderId: 31)?.at.timeIntervalSinceNow ?? .infinity), 5)
        XCTAssertNil(c.lastTerminalStatus(marketId: 2, contractOrderId: 31))
        // An order without one is never named by it.
        c.handle(frame(["mt": 24, "d": [["oid": 40, "mkt": 1, "t": 1, "st": 2, "p": 780000, "os": 100]]]))
        c.handle(frame(["mt": 24, "d": [["oid": 40, "mkt": 1, "st": 5, "r": true]]]))
        XCTAssertNil(c.lastTerminalStatus(marketId: 1, contractOrderId: 40))
    }

    /// Sends one add-margin request of 10 AUSD on `c` and acks it as frame `sn`: its request id.
    private func sendMargin(_ c: PerplTradeClient, _ wire: Wire, sn: Int) async throws -> Int {
        let sending = Task { try await c.sendEach([PerplOrders.addMargin(perpId: 1, amountCNS: 10_000_000, accountId: 10)]) }
        await until { wire.frames.count == sn }
        ack(c, sn: sn)
        let acks = try await sending.value
        return try XCTUnwrap(acks.first?.requestId)
    }

    /// An add-margin request on the stream (p4 spec A.4.3, #4): its own report never enters the live list nor takes an
    /// order's request; Canceled alone decides nothing; the position's collateral grown under its own request id is
    /// Perpl's word that it went in, by the measured amount.
    func testAMarginRequestOnTheStream() async throws {
        let c = client()
        let wire = signIn(c)
        c.handle(frame(["mt": 23, "d": [["oid": 31, "scid": 31, "rq": 480, "mkt": 1, "t": 1, "st": 2, "p": 780000, "os": 100, "fs": 0, "lv": 500]]]))
        c.handle(frame(["mt": 26, "d": [["pid": 7, "mkt": 1, "sd": 1, "s": 200, "st": 1, "c": "32000000"]]]))
        let rq = try await sendMargin(c, wire, sn: 1)
        XCTAssertEqual(wire.frames.first?["t"] as? Int, 6)
        XCTAssertEqual(wire.frames.first?["a"] as? String, "10000000")
        XCTAssertEqual(c.sentRequest(rq: rq)?.kind, .collateral)
        let orderKey = PerplOpenOrder.Key(marketId: 1, oid: 31)
        c.handle(frame(["mt": 24, "d": [["rq": rq, "mkt": 1, "oid": 31, "t": 6, "st": 5]]]))
        XCTAssertEqual(c.openOrders.map(\.oid), [31], "a t:6 report never enters the list")
        XCTAssertEqual(c.openOrders.first?.typeRaw, 1)
        XCTAssertEqual(c.requestId(for: orderKey), 480, "nor takes the order's request")
        XCTAssertNil(c.collateralOutcome(rq: rq, final: false))
        XCTAssertNil(c.collateralOutcome(rq: rq, final: true), "Canceled alone is never refused")
        XCTAssertNil(c.outcome(rq: rq, sent: try XCTUnwrap(c.sentRequest(rq: rq)), final: true), "never an order's outcome")
        XCTAssertFalse(c.sawPositionChange(rq: rq))
        c.handle(frame(["mt": 27, "d": [["pid": 7, "rq": rq, "st": 1, "c": "42000000"]]]))
        XCTAssertEqual(c.collateralAdded(rq: rq), 10_000_000)
        XCTAssertEqual(c.collateralOutcome(rq: rq, final: false), .added(deltaCNS: 10_000_000))
        XCTAssertTrue(c.sawPositionChange(rq: rq))
        // The order's own later fill still belongs to the order.
        c.handle(frame(["mt": 24, "d": [["oid": 31, "mkt": 1, "st": 4, "fs": 100, "r": true]]]))
        XCTAssertEqual(c.lastTerminalStatus(marketId: 1, contractOrderId: 31)?.status, 4)
        let census = c.drainCensus()
        XCTAssertEqual(census.marginWritten, 1)
        XCTAssertEqual(census.marginSt5or6, 1)
        XCTAssertEqual(census.marginPositionWithRq, 1)
        XCTAssertEqual(census.firstEventCarriedRq + census.firstEventLackedRq, 0, "a margin report never counts as an order's first event")
        XCTAssertEqual(census.foreignReports, 0)
        XCTAssertEqual(census.oidEqualsScid + census.oidDiffersFromScid + census.scidMissing, 0)
        XCTAssertEqual(census.cancelOwnEvents, 0)
    }

    /// A margin refusal is final at once (sr 36 with fr 2, sr 34) or only at the end with continuity (sr 15); a collateral
    /// growth without the request id counts only as exactly the amount, with the size unchanged, after the write.
    func testAMarginRefusalAndAGrowthWithoutItsRequestId() async throws {
        let c = client()
        let wire = signIn(c)
        c.handle(frame(["mt": 26, "d": [["pid": 7, "mkt": 1, "sd": 1, "s": 200, "st": 1, "c": "32000000"],
                                        ["pid": 8, "mkt": 2, "sd": 1, "s": 50, "st": 1, "c": "5000000"]]]))
        let refused = try await sendMargin(c, wire, sn: 1)
        c.handle(frame(["mt": 24, "d": [["rq": refused, "mkt": 1, "t": 6, "st": 7, "sr": 36, "fr": 2]]]))
        XCTAssertEqual(c.collateralOutcome(rq: refused, final: false), .refused(PerplOrderReason(status: 7, reason: 36, failure: 2)))
        let provisional = try await sendMargin(c, wire, sn: 2)
        c.handle(frame(["mt": 24, "d": [["rq": provisional, "mkt": 1, "t": 6, "st": 7, "sr": 15]]]))
        XCTAssertNil(c.collateralOutcome(rq: provisional, final: false))
        XCTAssertEqual(c.collateralOutcome(rq: provisional, final: true), .refused(PerplOrderReason(status: 7, reason: 15)))
        let since = Date()
        c.handle(frame(["mt": 27, "d": [["pid": 7, "st": 1, "c": "42000000"]]]))
        XCTAssertTrue(c.collateralGrowthWithoutRequest(pid: 7, amountCNS: 10_000_000, since: since))
        XCTAssertFalse(c.collateralGrowthWithoutRequest(pid: 7, amountCNS: 9_990_000, since: since), "exactly the amount")
        XCTAssertFalse(c.collateralGrowthWithoutRequest(pid: 7, amountCNS: 10_000_000, since: Date().addingTimeInterval(60)), "older than the write")
        c.handle(frame(["mt": 27, "d": [["pid": 8, "st": 1, "s": 60, "c": "15000000"]]]))
        XCTAssertFalse(c.collateralGrowthWithoutRequest(pid: 8, amountCNS: 10_000_000, since: since), "the size changed: a fill's collateral")
        XCTAssertNil(c.collateralAdded(rq: provisional), "a growth without its request id is never its own")
        let census = c.drainCensus()
        XCTAssertEqual(census.marginWritten, 2)
        XCTAssertEqual(census.marginSt7, 2)
        XCTAssertEqual(census.marginGrowthWithoutRq, 1)
    }

    /// A close ended the position only by a closed report carrying its own request id (#7): never by the request id a
    /// position carried from an earlier report.
    func testACloseEndsThePositionOnlyByItsOwnReport() {
        let c = client()
        signIn(c)
        c.handle(frame(["mt": 26, "d": [["pid": 7, "mkt": 1, "sd": 1, "s": 200, "st": 1], ["pid": 8, "mkt": 1, "sd": 2, "s": 50, "st": 1]]]))
        c.handle(frame(["mt": 27, "d": [["pid": 7, "rq": 12, "st": 2, "s": 0]]]))
        XCTAssertTrue(c.positionClosed(byRequest: 12))
        c.handle(frame(["mt": 27, "d": [["pid": 8, "rq": 20, "st": 1, "s": 40]]]))
        c.handle(frame(["mt": 27, "d": [["pid": 8, "st": 2, "s": 0]]]))
        XCTAssertFalse(c.positionClosed(byRequest: 20), "never the request it carried before")
        // Another account's report ends nothing of this one.
        c.handle(frame(["mt": 27, "d": [["pid": 9, "acc": 11, "mkt": 1, "sd": 1, "rq": 30, "st": 2, "s": 0]]]))
        XCTAssertFalse(c.positionClosed(byRequest: 30))
    }

    /// A close over the trading connection is a reduce-only order under its reserved request id, decided as any order is;
    /// a resting order's cancel names it by the stream's own order id and is confirmed by the sending socket's list.
    func testACloseAndACancelOverTheConnection() async throws {
        let c = client()
        let wire = signIn(c)
        let position = PerpPosition(perpId: 1, symbol: "BTC", side: .long, size: 0.002, entry: 80000, mark: 81650, margin: 32, unrealized: 0, premium: 0,
                                    leverage: 5, liquidation: nil, notional: 0)
        var close = PerplOrders.entry(PerplService.closeInput(market: btc(), position: position, size: 0.002, slippageBps: 100), accountId: 10, head: 0)
        let reserved = c.reserveRequestId()
        close.requestId = reserved
        let placing = Task { try await c.placeAll([close]) }
        await until { wire.frames.count == 1 }
        ack(c, sn: 1)
        let closeAcks = try await placing.value
        XCTAssertEqual(closeAcks.first?.accepted, true)
        XCTAssertEqual(wire.frames.first?["t"] as? Int, 3)
        XCTAssertEqual(wire.frames.first?["rq"] as? Int, reserved)
        XCTAssertEqual(wire.frames.first?["s"] as? Int, 200)
        let sent = try XCTUnwrap(c.sentRequest(rq: reserved))
        XCTAssertEqual(sent.kind, .entry(ioc: true, sizeRaw: 200))
        c.handle(frame(["mt": 24, "d": [["rq": reserved, "mkt": 1, "oid": 90, "t": 3, "st": 4, "os": 200, "fs": 200, "fp": 816100, "f": "56310", "r": true]]]))
        XCTAssertEqual(c.outcome(rq: reserved, sent: sent, final: false),
                       .filled(PerplFillSummary(filledSizeRaw: 200, requestedSizeRaw: 200, priceRaw: 816100, feeCNS: "56310", txid: nil)))

        c.handle(frame(["mt": 23, "d": [["oid": 31, "scid": 31, "rq": 480, "mkt": 1, "t": 1, "st": 2, "p": 780000, "os": 100, "lv": 500]]]))
        let cancelling = Task { try await c.sendEach([PerplOrders.cancel(perpId: 1, orderId: 31, accountId: 10, head: 0)]) }
        await until { wire.frames.count == 2 }
        XCTAssertEqual(wire.frames.last?["oid"] as? Int, 31)
        ack(c, sn: 2)
        let cancelAcks = try await cancelling.value
        let cancelRq = try XCTUnwrap(cancelAcks.first?.requestId)
        c.handle(frame(["mt": 24, "d": [["oid": 31, "mkt": 1, "st": 5, "sr": 28, "r": true]]]))
        XCTAssertEqual(c.cancelResult(of: PerplOpenOrder.Key(marketId: 1, oid: 31), cancelRq: cancelRq), .cancelled)
        XCTAssertEqual(c.lastTerminalStatus(marketId: 1, contractOrderId: 31)?.status, 5)
    }
}
