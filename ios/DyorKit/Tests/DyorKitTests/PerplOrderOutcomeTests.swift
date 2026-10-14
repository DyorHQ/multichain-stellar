import BigInt
import XCTest
@testable import DyorKit

/// What Perpl did with an order the app sent, read from the stream: Perpl's deduplication rule, the outcome of each kind of
/// request, the reasons in words, the outcome deadline, the trading heartbeat, the device's request-id high-water mark and
/// the chain evidence of a fill. Pure: no socket, no I/O.
final class PerplOrderOutcomeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ json: [String: Any], snapshot: Bool = false) -> PerplOrderEvent {
        PerplOrderEvent(json: json, snapshot: snapshot)!
    }

    private func ledger(_ events: [[String: Any]], account: Int = 10) -> PerplOrderLedger {
        var ledger = PerplOrderLedger(account: account)
        for json in events { _ = ledger.apply(event(json), at: now) }
        return ledger
    }

    private func ioc(_ size: Int = 100) -> PerplSentRequest {
        PerplSentRequest(accountId: 10, marketId: 1, wireType: 1, lotLNS: size, kind: .entry(ioc: true, sizeRaw: size), writtenAt: now)
    }

    private func limit(_ size: Int = 100) -> PerplSentRequest {
        PerplSentRequest(accountId: 10, marketId: 1, wireType: 1, lotLNS: size, kind: .entry(ioc: false, sizeRaw: size), writtenAt: now)
    }

    private let trigger = PerplSentRequest(accountId: 10, marketId: 1, wireType: 3, lotLNS: 100, kind: .trigger, writtenAt: Date(timeIntervalSince1970: 1_800_000_000))

    private func summary(_ filled: Int, of requested: Int = 100, price: Int? = nil, fee: String? = nil, txid: String? = nil) -> PerplFillSummary {
        PerplFillSummary(filledSizeRaw: filled, requestedSizeRaw: requested, priceRaw: price, feeCNS: fee, txid: txid)
    }

    private func reason(_ sr: Int, status: Int = 5, fr: Int? = nil) -> PerplOrderReason { PerplOrderReason(status: status, reason: sr, failure: fr) }

    // MARK: 1–3 Deduplication and finality

    func testDeduplication() {
        // The first non-failure is definitive: a later failure (a resent request's echo) is ignored.
        XCTAssertEqual(ledger([["rq": 6, "mkt": 1, "st": 4, "fs": 100], ["rq": 6, "st": 7, "sr": 32]]).outcome(rq: 6, sent: ioc(), final: false),
                       .filled(summary(100)))
        // A provisional failure is replaced by a later non-failure.
        XCTAssertEqual(ledger([["rq": 6, "st": 7, "sr": 15], ["rq": 6, "st": 4]]).outcome(rq: 6, sent: ioc(), final: false), .filled(summary(100)))
        // A request-level refusal is final at once, even with no order id (no on-chain order was assigned).
        let forwarding = ledger([["rq": 6, "mkt": 1, "st": 7, "sr": 34]])
        XCTAssertEqual(forwarding.outcome(rq: 6, sent: ioc(), final: false), .failed(reason(34, status: 7)))
        XCTAssertEqual(PerplOrderReason(status: 7, reason: 34).message,
                       "Perpl hasn't registered one-click trading for your account yet. Wait a few seconds and try again.")
        // Any other failure waits for the deadline: exposed as provisional, final only then.
        let balance = ledger([["rq": 6, "st": 7, "sr": 1]])
        XCTAssertNil(balance.outcome(rq: 6, sent: ioc(), final: false))
        XCTAssertEqual(balance.provisionalFailure(rq: 6, accountId: 10), reason(1, status: 7))
        XCTAssertEqual(balance.outcome(rq: 6, sent: ioc(), final: true), .failed(reason(1, status: 7)))
        // A settlement refusal the Exchange evaluated (it carries `fr`) is final at once.
        let margin = ledger([["rq": 6, "st": 7, "sr": 44, "fr": 1]])
        XCTAssertEqual(margin.outcome(rq: 6, sent: ioc(), final: false), .failed(reason(44, status: 7, fr: 1)))
        XCTAssertNil(margin.provisionalFailure(rq: 6, accountId: 10))
        // Two failures: the first is the answer.
        XCTAssertEqual(ledger([["rq": 6, "st": 7, "sr": 1], ["rq": 6, "st": 7, "sr": 18]]).outcome(rq: 6, sent: ioc(), final: true), .failed(reason(1, status: 7)))
        // A provisional failure with `r` is still the failure's to decide, never "not filled".
        XCTAssertNil(ledger([["rq": 6, "st": 7, "sr": 1, "r": true]]).outcome(rq: 6, sent: ioc(), final: false))
    }

    func testExpiry() {
        XCTAssertEqual(ledger([["rq": 6, "st": 6]]).outcome(rq: 6, sent: ioc(), final: false), .expired)
        XCTAssertEqual(ledger([["rq": 6, "oid": 77, "mkt": 1, "st": 2], ["rq": 6, "st": 6]]).outcome(rq: 6, sent: limit(), final: false), .expired)
        XCTAssertEqual(ledger([["rq": 6, "st": 3, "fs": 40], ["rq": 6, "st": 6]]).outcome(rq: 6, sent: limit(), final: false),
                       .partlyFilled(summary(40), rest: .expired))
    }

    func testContinuity() {
        // A provisional failure without continuity (the socket reconnected): still undecided, the tracker reconciles it.
        XCTAssertNil(ledger([["rq": 6, "st": 7, "sr": 1]]).outcome(rq: 6, sent: ioc(), final: false))
    }

    // MARK: 4–7 Entries

    func testImmediateOrCancel() {
        XCTAssertEqual(ledger([["rq": 6, "st": 4, "fs": 100, "os": 100]]).outcome(rq: 6, sent: ioc(), final: false), .filled(summary(100)))
        XCTAssertEqual(ledger([["rq": 6, "st": 4, "fs": 40, "os": 100]]).outcome(rq: 6, sent: ioc(), final: false),
                       .partlyFilled(summary(40), rest: .cancelled(reason(16))))
        XCTAssertEqual(ledger([["rq": 6, "st": 5, "sr": 16, "fs": 40]]).outcome(rq: 6, sent: ioc(), final: false),
                       .partlyFilled(summary(40), rest: .cancelled(reason(16))))
        XCTAssertEqual(ledger([["rq": 6, "st": 5, "sr": 16, "fs": 0]]).outcome(rq: 6, sent: ioc(), final: false), .notFilled(reason(16)))
        var interim = ledger([["rq": 6, "st": 3, "fs": 40]])
        XCTAssertNil(interim.outcome(rq: 6, sent: ioc(), final: false), "an IOC still matching is undecided")
        _ = interim.apply(event(["rq": 6, "st": 4, "fs": 100]), at: now)
        XCTAssertEqual(interim.outcome(rq: 6, sent: ioc(), final: false), .filled(summary(100)))
    }

    func testRemovedWithoutATerminalStatus() {
        XCTAssertEqual(ledger([["rq": 6, "st": 3, "fs": 40], ["rq": 6, "r": true]]).outcome(rq: 6, sent: ioc(), final: false),
                       .partlyFilled(summary(40), rest: .cancelled(reason(16))))
        XCTAssertEqual(ledger([["rq": 6, "r": true, "fs": 0]]).outcome(rq: 6, sent: ioc(), final: false), .notFilled(reason(16)))
        XCTAssertEqual(ledger([["rq": 6, "mkt": 1, "oid": 77, "st": 2], ["rq": 6, "r": true]]).outcome(rq: 6, sent: limit(), final: false),
                       .cancelled(reason(0)))
    }

    func testTheDeadlineSettlesAnImmediateOrCancel() {
        XCTAssertEqual(ledger([["rq": 6, "st": 3, "fs": 40]]).outcome(rq: 6, sent: ioc(), final: true),
                       .partlyFilled(summary(40), rest: .cancelled(reason(16))))
        // Only the fills joined (no `fs`): the size is theirs, the price their size-weighted average.
        var fills = ledger([["rq": 6, "mkt": 1, "oid": 77, "st": 2]])
        _ = fills.apply(PerplFillEvent(marketId: 1, orderId: 77, accountId: 10, priceRaw: 816000, sizeRaw: 10, feeCNS: "100"), at: now)
        _ = fills.apply(PerplFillEvent(marketId: 1, orderId: 77, accountId: 10, priceRaw: 816200, sizeRaw: 30, feeCNS: "-20"), at: now)
        XCTAssertNil(fills.outcome(rq: 6, sent: ioc(), final: false))
        XCTAssertEqual(fills.outcome(rq: 6, sent: ioc(), final: true),
                       .partlyFilled(summary(40, price: 816150, fee: "80"), rest: .cancelled(reason(16))))
        // Nothing filled and no status: unconfirmed is the caller's (nil here), never "not filled".
        XCTAssertNil(ledger([["rq": 6, "mkt": 1, "oid": 77, "st": 1]]).outcome(rq: 6, sent: ioc(), final: true))
    }

    func testLimitOrders() {
        XCTAssertEqual(ledger([["rq": 6, "mkt": 1, "oid": 77, "st": 2]]).outcome(rq: 6, sent: limit(), final: false), .resting(orderId: 77))
        XCTAssertEqual(ledger([["rq": 6, "mkt": 1, "oid": 77, "st": 3, "fs": 40]]).outcome(rq: 6, sent: limit(), final: false),
                       .partlyFilled(summary(40), rest: .resting(orderId: 77)))
        XCTAssertEqual(ledger([["rq": 6, "mkt": 1, "oid": 77, "st": 2], ["rq": 6, "st": 4, "fs": 100]]).outcome(rq: 6, sent: limit(), final: false),
                       .filled(summary(100)))
        // Cancelled before any fill — by the user, from Orders or the Perpl web app: not a failure, no notice.
        let cancelled = ledger([["rq": 6, "mkt": 1, "oid": 77, "st": 2], ["rq": 6, "st": 5, "sr": 28, "fs": 0]]).outcome(rq: 6, sent: limit(), final: false)
        XCTAssertEqual(cancelled, .cancelled(reason(28)))
        XCTAssertEqual(cancelled?.tone, .neutral)
        XCTAssertEqual(cancelled?.executedNothing, true)
    }

    // MARK: 8–12 Joining

    func testAPartialUpdateWithoutARequestIdJoinsByItsOrder() {
        XCTAssertEqual(ledger([["rq": 6, "mkt": 1, "oid": 77, "st": 2], ["oid": 77, "st": 4, "fs": 100, "fp": 816155]]).outcome(rq: 6, sent: limit(), final: false),
                       .filled(summary(100, price: 816155)))
    }

    func testAReusedOrderIdNeverJoinsAFinishedRequest() {
        var ledger = ledger([["rq": 6, "mkt": 1, "oid": 77, "st": 4, "fs": 100]])
        XCTAssertNil(ledger.requestId(for: PerplOpenOrder.Key(marketId: 1, oid: 77), accountId: 10), "a terminal request's key is forgotten")
        XCTAssertEqual(ledger.apply(event(["oid": 77, "mkt": 1, "st": 2]), at: now).changed, [])
        XCTAssertEqual(ledger.outcome(rq: 6, sent: limit(), final: false), .filled(summary(100)))
    }

    /// Perpl reuses an order id within seconds: the ended request's late fill and rq-less report stay its own (never
    /// buffered for the next request), and the next request's outcome never carries the earlier order's fill, fee or
    /// volume; a report older than the next request's write is dropped, not drained into it.
    func testALateFillOfAnEndedOrderNeverJoinsTheNextOneUnderItsId() {
        var ledger = PerplOrderLedger(account: 10)
        let a = PerplSentRequest(accountId: 10, marketId: 1, wireType: 1, lotLNS: 100, kind: .entry(ioc: true, sizeRaw: 100), writtenAt: now)
        ledger.noteSent(a, rq: 6)
        // A fills in block 500 and ends; its order id is free again.
        XCTAssertEqual(ledger.apply(event(["rq": 6, "mkt": 1, "oid": 77, "st": 4, "fs": 100, "at": ["b": 500]]), at: now).changed, [6])
        XCTAssertNil(ledger.requestId(for: PerplOpenOrder.Key(marketId: 1, oid: 77), accountId: 10))
        // A's fill arrives after its terminal report: A's, not buffered.
        XCTAssertEqual(ledger.apply(PerplFillEvent(marketId: 1, orderId: 77, accountId: 10, priceRaw: 816_000, sizeRaw: 60, feeCNS: "200", block: 500), at: now), [6])
        XCTAssertEqual(ledger.outcome(rq: 6, sent: a, final: false), .filled(summary(100, price: 816_000, fee: "200")))
        // A late rq-less report of A (st 4, its block): absorbed by A, never a terminal report for whatever comes next.
        XCTAssertEqual(ledger.apply(event(["oid": 77, "mkt": 1, "st": 4, "at": ["b": 500]]), at: now).changed, [])
        // A fill from a later block before B was written: nobody's yet (buffered), and too old for B (dropped at its drain).
        XCTAssertEqual(ledger.apply(PerplFillEvent(marketId: 1, orderId: 77, accountId: 10, priceRaw: 999_999, sizeRaw: 100, feeCNS: "999", block: 505), at: now), [])

        // B reuses the id: written a second later, filled in block 510 with no price or fee of its own on its report.
        let b = PerplSentRequest(accountId: 10, marketId: 1, wireType: 1, lotLNS: 100, kind: .entry(ioc: true, sizeRaw: 100), writtenAt: now.addingTimeInterval(1))
        ledger.noteSent(b, rq: 7)
        XCTAssertEqual(ledger.apply(event(["rq": 7, "mkt": 1, "oid": 77, "st": 2, "at": ["b": 510]]), at: now.addingTimeInterval(2)).changed, [7])
        // Another late fill of A (its block) while B is live: still A's.
        XCTAssertEqual(ledger.apply(PerplFillEvent(marketId: 1, orderId: 77, accountId: 10, priceRaw: 816_000, sizeRaw: 40, feeCNS: "145", block: 500),
                                    at: now.addingTimeInterval(2)), [6])
        XCTAssertEqual(ledger.apply(event(["oid": 77, "mkt": 1, "st": 4, "fs": 100, "at": ["b": 511]]), at: now.addingTimeInterval(3)).changed, [7])
        XCTAssertEqual(ledger.outcome(rq: 7, sent: b, final: false), .filled(summary(100)), "none of A's price, fee or fills")
        XCTAssertEqual(ledger.outcome(rq: 6, sent: a, final: false), .filled(summary(100, price: 816_000, fee: "345")), "A stays as decided")
    }

    func testFillsJoinTheirOrder() {
        var ledger = PerplOrderLedger(account: 10)
        // A fill that arrives before the event mapping its order waits for it.
        XCTAssertEqual(ledger.apply(PerplFillEvent(marketId: 1, orderId: 77, accountId: 10, priceRaw: 816000, sizeRaw: 100, feeCNS: "345"), at: now), [])
        // Another account's fill never joins this account's request.
        XCTAssertEqual(ledger.apply(PerplFillEvent(marketId: 1, orderId: 77, accountId: 11, priceRaw: 1, sizeRaw: 100, feeCNS: "9"), at: now), [])
        XCTAssertEqual(ledger.apply(event(["rq": 6, "mkt": 1, "oid": 77, "st": 2]), at: now).changed, [6])
        XCTAssertEqual(ledger.apply(PerplFillEvent(marketId: 1, orderId: 77, accountId: 11, priceRaw: 1, sizeRaw: 100, feeCNS: "9"), at: now), [])
        _ = ledger.apply(event(["rq": 6, "st": 4, "fs": 100]), at: now)
        // No `fp` and no `f`: the fills' average price and summed fee.
        XCTAssertEqual(ledger.outcome(rq: 6, sent: limit(), final: false), .filled(summary(100, price: 816000, fee: "345")))
    }

    func testAnotherOrdersReportUnderTheSameIdIsForeign() {
        let sent = PerplSentRequest(accountId: 10, marketId: 1, wireType: 1, lotLNS: 100, kind: .entry(ioc: true, sizeRaw: 100), writtenAt: now)
        XCTAssertEqual(ledger([["rq": 6, "mkt": 1, "t": 2, "os": 100, "st": 4]]).outcome(rq: 6, sent: sent, final: false), .unconfirmed(.foreignReport))
        XCTAssertEqual(ledger([["rq": 6, "mkt": 20, "st": 4]]).outcome(rq: 6, sent: sent, final: false), .unconfirmed(.foreignReport))
        XCTAssertEqual(ledger([["rq": 6, "mkt": 1, "t": 1, "os": 90, "st": 4]]).outcome(rq: 6, sent: sent, final: false), .unconfirmed(.foreignReport))
        XCTAssertEqual(ledger([["rq": 6, "mkt": 1, "t": 1, "os": 100, "st": 4, "fs": 100]]).outcome(rq: 6, sent: sent, final: false), .filled(summary(100)))
    }

    func testAnotherAccountsEventChangesNothing() {
        let other = ledger([["rq": 6, "acc": 11, "st": 4, "fs": 100]])
        XCTAssertNil(other.outcome(rq: 6, sent: ioc(), final: true))
        XCTAssertNil(PerplOrderLedger(account: nil).outcome(rq: 6, sent: ioc(), final: true))
    }

    // MARK: 13 Take-profit / stop-loss, and cancel requests

    func testTriggers() {
        XCTAssertEqual(ledger([["rq": 12, "mkt": 1, "oid": 40, "t": 3, "st": 8, "tp": 900000]]).outcome(rq: 12, sent: trigger, final: false), .armed)
        XCTAssertEqual(ledger([["rq": 12, "st": 8], ["rq": 12, "st": 9, "sr": 54]]).outcome(rq: 12, sent: trigger, final: false), .triggered)
        XCTAssertEqual(ledger([["rq": 12, "st": 8], ["rq": 12, "st": 5, "sr": 28, "r": true]]).outcome(rq: 12, sent: trigger, final: false), .cancelled(reason(28)))
        XCTAssertEqual(ledger([["rq": 12, "st": 8], ["rq": 12, "r": true]]).outcome(rq: 12, sent: trigger, final: false), .cancelled(reason(0)))
        let refused = ledger([["rq": 13, "st": 7, "sr": 57]])
        XCTAssertNil(refused.outcome(rq: 13, sent: trigger, final: false))
        XCTAssertEqual(refused.outcome(rq: 13, sent: trigger, final: true), .failed(reason(57, status: 7)))
    }

    func testACancelRequestNeverMergesIntoItsTarget() {
        let cancel = PerplSentRequest(accountId: 10, marketId: 1, wireType: 5, lotLNS: 0, kind: .cancel, writtenAt: now)
        var ledger = PerplOrderLedger(account: 10)
        _ = ledger.apply(event(["rq": 12, "mkt": 1, "oid": 5, "t": 3, "st": 8]), at: now)
        ledger.noteSent(cancel, rq: 9)
        // Its own report names the target: returned as the target, never mapped to it.
        let pending = ledger.apply(event(["rq": 9, "mkt": 1, "oid": 5, "t": 5, "st": 1]), at: now)
        XCTAssertEqual(pending.changed, [9])
        XCTAssertEqual(pending.cancelTarget?.key, PerplOpenOrder.Key(marketId: 1, oid: 5))
        XCTAssertEqual(pending.cancelTarget?.status, 1)
        XCTAssertEqual(ledger.requestId(for: PerplOpenOrder.Key(marketId: 1, oid: 5), accountId: 10), 12, "the target keeps its own request")
        XCTAssertEqual(ledger.outcome(rq: 12, sent: trigger, final: false), .armed)
        // A partial update of the cancel without `t` is still the cancel's.
        _ = ledger.apply(event(["rq": 9, "mkt": 1, "oid": 5, "st": 7, "sr": 45]), at: now)
        XCTAssertEqual(ledger.outcome(rq: 9, sent: cancel, final: false), .failed(reason(45, status: 7)))
        XCTAssertEqual(ledger.outcome(rq: 12, sent: trigger, final: false), .armed)
        // One that went through.
        var through = PerplOrderLedger(account: 10)
        let done = through.apply(event(["rq": 10, "mkt": 1, "oid": 5, "t": 5, "st": 4]), at: now)
        XCTAssertEqual(done.cancelTarget?.status, 4)
        XCTAssertEqual(through.outcome(rq: 10, sent: cancel, final: false), .cancelled(reason(28)))
    }

    // MARK: 14 Reasons

    func testReasonsInWords() {
        let table: [(Int, String)] = [
            (34, "Perpl hasn't registered one-click trading for your account yet. Wait a few seconds and try again."),
            (32, "Perpl didn't take this order because it clashed with another one from your account. Nothing was placed. Try again."),
            (59, "Perpl didn't take this order because it clashed with another one from your account. Nothing was placed. Try again."),
            (14, "Perpl couldn't execute it in time, so nothing was placed."),
            (13, "It would have filled at once, so Perpl didn't post it as a post-only order."),
            (16, "There wasn't enough on the order book within the slippage limit."),
            (28, "It was cancelled."), (29, "Perpl cancelled it."), (30, "It was cancelled by a liquidation."),
            (24, "Your account has the most open orders Perpl allows. Cancel some first."),
            (27, "This market's order book is full. Try again later."),
            (2, "Your Perpl account is frozen, so it can't trade right now. Contact Perpl for help."),
            (7, "Your Perpl account is frozen, so it can't trade right now. Contact Perpl for help."),
            (19, "Your Perpl account is frozen, so it can't trade right now. Contact Perpl for help."),
            (12, "This market isn't trading right now. Try again later."),
            (10, "This close is larger than your open position, so Perpl refused it."),
            (11, "There is no position on that side for this order to close."),
            (17, "The order is below Perpl's minimum for this market."), (39, "The order is below Perpl's minimum for this market."),
            (1, "There isn't enough available balance on your Perpl account."), (18, "There isn't enough available balance on your Perpl account."),
            (41, "There isn't enough available balance on your Perpl account."),
            (40, "The price is outside what Perpl accepts on this market."),
            (38, "The size is outside what Perpl accepts on this market."), (42, "The size is outside what Perpl accepts on this market."),
            (25, "It reached Perpl's limit of matches for one order. Try a smaller size."),
            (46, "It couldn't fill in full, so nothing was filled."),
            (33, "The order no longer exists on Perpl."), (45, "Perpl couldn't cancel it."), (50, "That order belongs to another account."),
            (57, "Perpl refused the take-profit or stop-loss (its price, size or position)."),
            (58, "Perpl refused the take-profit or stop-loss (its price, size or position)."),
            (15, "Perpl couldn't send it to Monad, so nothing was placed. Try again."),
            (37, "Perpl can't settle trades on this market right now."), (53, "Perpl can't settle trades on this market right now."),
            (5, "Perpl refused the order's time limit. Try again."), (20, "Perpl refused the order's time limit. Try again."),
            (64, "It triggered, but Perpl couldn't execute it."), (67, "It triggered, but expired before it could execute."),
            (36, "Perpl couldn't post it to the order book."), (23, "Perpl couldn't settle it."), (44, "Perpl couldn't settle it."),
            (0, "Perpl didn't execute it."), (99, "Perpl refused it (reason 99)."),
        ]
        for (sr, english) in table { XCTAssertEqual(PerplOrderReason(status: 7, reason: sr).message, english, "sr \(sr)") }
        // `fr` is read first with sr 23, 36 and 44 (and only there).
        let failures: [(Int, String)] = [
            (1, "There isn't enough available margin on your Perpl account for this order."),
            (2, "There isn't enough available margin to add to this position."),
            (3, "There isn't enough available margin to turn this position around."),
            (4, "There is no position on that side for this order to close."),
            (5, "Settling at this price would leave the market insolvent, so Perpl refused it."),
            (6, "Closing at this price would leave the position with a negative value, so Perpl refused it."),
            (7, "Perpl had no fresh price for this market. Try again in a moment."),
            (8, "Filling it would carry more unrealized loss than this order allows."),
            (9, "Perpl couldn't settle it."),
        ]
        for sr in [23, 36, 44] {
            for (fr, english) in failures { XCTAssertEqual(PerplOrderReason(status: 7, reason: sr, failure: fr).message, english, "sr \(sr) fr \(fr)") }
        }
        XCTAssertEqual(PerplOrderReason(status: 7, reason: 36, failure: 99).message, "Perpl couldn't post it to the order book.", "an unknown fr falls back to sr")
        XCTAssertEqual(PerplOrderReason(status: 7, reason: 16, failure: 1).message, "There wasn't enough on the order book within the slippage limit.")
        for sr in [14, 32, 34, 59] { XCTAssertTrue(PerplOrderReason(status: 7, reason: sr).isFinalAtOnce, "sr \(sr)") }
        for sr in [0, 1, 15, 16, 23, 33, 44, 57] { XCTAssertFalse(PerplOrderReason(status: 7, reason: sr).isFinalAtOnce, "sr \(sr)") }
        XCTAssertTrue(PerplOrderReason(status: 7, reason: 23, failure: 9).isFinalAtOnce)
        // The reason code goes in as plain digits in every language.
        let saved = L10n.locale
        defer { L10n.locale = saved }
        L10n.locale = Locale(identifier: "fr_FR")
        XCTAssertTrue(PerplOrderReason(status: 7, reason: 1234).message.contains("1234"))
    }

    // MARK: 15 Volume

    func testVolumeComesOnlyFromWhatFilled() {
        let filled = PerplOrderOutcome.filled(summary(100, price: 816155))
        XCTAssertEqual(filled.volumeUSD(priceDecimals: 1, lotDecimals: 5) ?? 0, 81.6155, accuracy: 1e-9)
        XCTAssertEqual(PerplOrderOutcome.partlyFilled(summary(40, price: 816155), rest: .cancelled(reason(16))).volumeUSD(priceDecimals: 1, lotDecimals: 5) ?? 0,
                       32.6462, accuracy: 1e-9)
        let none: [PerplOrderOutcome] = [
            .notFilled(reason(16)), .failed(reason(1, status: 7)), .expired, .cancelled(reason(28)), .resting(orderId: 7),
            .unconfirmed(.timedOut), .unconfirmed(.connectionLost), .armed, .triggered,
            .observed(PerplPositionEvidence.Growth(side: .long, size: 0.001, price: 81650, attributable: false)),
            .filled(summary(100)), // no price: never the mark
        ]
        for outcome in none { XCTAssertNil(outcome.volumeUSD(priceDecimals: 1, lotDecimals: 5), "\(outcome)") }
        XCTAssertEqual(PerplOrderOutcome.observed(PerplPositionEvidence.Growth(side: .long, size: 0.001, price: 81650, attributable: true))
            .volumeUSD(priceDecimals: 1, lotDecimals: 5) ?? 0, 81.65, accuracy: 1e-9)
        XCTAssertEqual(PerplFillSummary(filledSizeRaw: 1, requestedSizeRaw: 1, priceRaw: 1, feeCNS: "-1250000", txid: nil).feeUSD ?? 0, -1.25, accuracy: 1e-12)
        // What may still change, and what executed nothing.
        XCTAssertTrue(PerplOrderOutcome.resting(orderId: 1).canStillChange)
        XCTAssertTrue(PerplOrderOutcome.partlyFilled(summary(40), rest: .resting(orderId: 1)).canStillChange)
        XCTAssertFalse(PerplOrderOutcome.partlyFilled(summary(40), rest: .expired).canStillChange)
        XCTAssertEqual([PerplOrderOutcome.notFilled(reason(16)), .failed(reason(1)), .expired, .cancelled(reason(28)), filled].map(\.executedNothing),
                       [true, true, true, true, false])
        XCTAssertEqual([filled, .resting(orderId: 1), .armed, .partlyFilled(summary(1), rest: .expired), .notFilled(reason(16)), .cancelled(reason(28))].map(\.tone),
                       [.success, .success, .success, .warning, .failure, .neutral])
    }

    // MARK: 16 Deadline and heartbeat

    func testTheOutcomeDeadline() {
        let deadline = PerplOutcomeDeadline(ackHead: 500, ttlBlocks: 20, ackAt: now)
        XCTAssertEqual(deadline.block, 525)
        XCTAssertEqual(deadline.wallClock, now.addingTimeInterval(12))
        XCTAssertEqual(PerplOutcomeDeadline(ackHead: 500, ttlBlocks: nil, ackAt: now).block, 525, "no ttl → 20")
        XCTAssertEqual(PerplOutcomeDeadline(ackHead: 500, ttlBlocks: 0, ackAt: now).block, 525, "below 20 → 20")
        XCTAssertEqual(PerplOutcomeDeadline(ackHead: 500, ttlBlocks: 30, ackAt: now).block, 535)
        XCTAssertNil(PerplOutcomeDeadline(ackHead: nil, ttlBlocks: 20, ackAt: now).block)
        XCTAssertFalse(deadline.hasPassed(head: 524, now: now.addingTimeInterval(11)))
        XCTAssertTrue(deadline.hasPassed(head: 525, now: now))
        XCTAssertTrue(deadline.hasPassed(head: nil, now: now.addingTimeInterval(12)))
    }

    func testHeartbeats() {
        var beat = PerplHeartbeat()
        beat.snapshot(sn: 100)
        XCTAssertEqual(beat.beat(sn: 101, head: 9_000, at: now), .inOrder)
        XCTAssertEqual(beat.beat(sn: 102, head: 9_001, at: now), .inOrder)
        XCTAssertFalse(beat.suspect)
        XCTAssertEqual(beat.beat(sn: 105, head: 9_004, at: now), .gap(missed: 2))
        XCTAssertTrue(beat.suspect)
        XCTAssertEqual(beat.gaps, 1)
        XCTAssertEqual(beat.lastGapAt, now)
        beat.snapshotsArrived()
        XCTAssertFalse(beat.suspect)
        XCTAssertEqual(beat.beat(sn: 104, head: 8_000, at: now), .stale)
        XCTAssertEqual(beat.head, 9_004, "a stale beat never moves the head back")

        // A fresh socket whose heartbeats don't continue the snapshot's sequence: re-seeded once, not a gap.
        var fresh = PerplHeartbeat()
        fresh.snapshot(sn: 100)
        XCTAssertEqual(fresh.beat(sn: 500, head: 1, at: now), .unseeded(expected: 101, got: 500))
        XCTAssertEqual(fresh.gaps, 0)
        XCTAssertEqual(fresh.beat(sn: 503, head: 2, at: now), .gap(missed: 2))
        XCTAssertFalse(fresh.suspect, "no in-order beat since the snapshot yet")
        XCTAssertEqual(fresh.beat(sn: 504, head: 3, at: now), .inOrder)
        XCTAssertEqual(fresh.beat(sn: 507, head: 4, at: now), .gap(missed: 2))
        XCTAssertTrue(fresh.suspect)
        XCTAssertEqual(fresh.beat(sn: nil, head: 50, at: now), .inOrder, "a beat without a sequence only moves the head")
        XCTAssertEqual(fresh.head, 50)
    }

    // MARK: 17 Request-id high-water mark

    func testTheRequestIdHighWaterMark() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = PerplRequestIdStore(defaults: defaults)
        XCTAssertEqual(PerplRequestIdStore.key(chainId: 143, accountId: 10), "perpl.rq.highWater.v1.143.10")
        XCTAssertEqual(store.highWater(chainId: 143, accountId: 10), 0)
        store.record(7, chainId: 143, accountId: 10)
        XCTAssertEqual(store.highWater(chainId: 143, accountId: 10), 7)
        store.record(3, chainId: 143, accountId: 10)
        XCTAssertEqual(store.highWater(chainId: 143, accountId: 10), 7, "never lowered")
        XCTAssertEqual(store.highWater(chainId: 143, accountId: 11), 0, "accounts are independent")
        XCTAssertEqual(store.highWater(chainId: 10143, accountId: 10), 0, "chains are independent")
    }

    // MARK: 18 Chain evidence

    private func position(_ side: PositionSide, _ size: Double, at entry: Double) -> PerpPosition {
        PerpPosition(perpId: 1, symbol: "BTC", side: side, size: size, entry: entry, mark: entry, margin: 10, unrealized: 0, premium: 0,
                     leverage: 5, liquidation: nil, notional: size * entry)
    }

    func testChainEvidence() throws {
        let opened = try XCTUnwrap(PerplPositionEvidence.growth(side: .long, before: nil, after: position(.long, 0.001, at: 81650), expected: 0.001, lot: 0.00001, attributable: true))
        XCTAssertEqual(opened.size, 0.001, accuracy: 1e-12)
        XCTAssertEqual(opened.price ?? 0, 81650, accuracy: 1e-6)
        XCTAssertTrue(opened.attributable)
        let added = try XCTUnwrap(PerplPositionEvidence.growth(side: .long, before: position(.long, 0.001, at: 80000), after: position(.long, 0.002, at: 80825),
                                                               expected: 0.001, lot: 0.00001, attributable: false))
        XCTAssertEqual(added.size, 0.001, accuracy: 1e-12)
        XCTAssertEqual(added.price ?? 0, 81650, accuracy: 1e-6)
        XCTAssertNil(PerplPositionEvidence.growth(side: .long, before: nil, after: position(.long, 0.002, at: 81650), expected: 0.001, lot: 0.00001, attributable: true),
                     "more than the order could add: other fills mixed in")
        XCTAssertNil(PerplPositionEvidence.growth(side: .long, before: position(.short, 0.001, at: 80000), after: position(.long, 0.001, at: 81650),
                                                  expected: 0.002, lot: 0.00001, attributable: true), "a flip is ambiguous")
        XCTAssertNil(PerplPositionEvidence.growth(side: .long, before: position(.long, 0.002, at: 80000), after: position(.long, 0.001, at: 80000),
                                                  expected: 0.001, lot: 0.00001, attributable: true), "it shrank")
        XCTAssertNil(PerplPositionEvidence.expectedGrowth(orderSide: .long, size: 0.002, reduceOnly: true, held: nil))
        XCTAssertNil(PerplPositionEvidence.expectedGrowth(orderSide: .long, size: 0.002, reduceOnly: false, held: (.short, 0.003)))
        XCTAssertEqual(PerplPositionEvidence.expectedGrowth(orderSide: .long, size: 0.005, reduceOnly: false, held: (.short, 0.003)) ?? 0, 0.002, accuracy: 1e-12)
        XCTAssertEqual(PerplPositionEvidence.expectedGrowth(orderSide: .long, size: 0.005, reduceOnly: false, held: (.long, 0.003)), 0.005)
        XCTAssertTrue(PerplPositionEvidence.isAttributable(beforeAge: 5, otherTrackedOrders: false, restingOnSide: false))
        XCTAssertFalse(PerplPositionEvidence.isAttributable(beforeAge: 5, otherTrackedOrders: true, restingOnSide: false))
        XCTAssertFalse(PerplPositionEvidence.isAttributable(beforeAge: 5, otherTrackedOrders: false, restingOnSide: true))
        XCTAssertFalse(PerplPositionEvidence.isAttributable(beforeAge: 61, otherTrackedOrders: false, restingOnSide: false))
    }

    // MARK: Parsing and the census

    func testParsing() throws {
        XCTAssertNil(PerplOrderEvent(json: ["st": 7, "sr": 34], snapshot: false), "neither a request id nor an order id")
        let failure = try XCTUnwrap(PerplOrderEvent(json: ["rq": 6, "st": 7, "sr": 34, "oid": 0, "scid": 0], snapshot: false))
        XCTAssertNil(failure.orderId)
        XCTAssertNil(failure.contractOrderId)
        let order = try XCTUnwrap(PerplOrderEvent(json: ["rq": NSNumber(value: 6), "oid": 77, "scid": 78, "mkt": 1, "acc": 10, "t": 5, "r": 1, "f": NSNumber(value: 345),
                                                         "at": ["b": 9, "txid": "0xABCD", "l": 3]], snapshot: true))
        XCTAssertEqual(order.requestId, 6)
        XCTAssertEqual(order.contractOrderId, 78)
        XCTAssertTrue(order.isCancelRequest)
        XCTAssertTrue(order.removed)
        XCTAssertTrue(order.isSnapshot)
        XCTAssertEqual(order.feeCNS, "345")
        XCTAssertEqual(order.txid, "0xabcd")
        XCTAssertEqual(order.block, 9)
        XCTAssertEqual(order.logIndex, 3)
        XCTAssertEqual(PerplOrderEvent(json: ["oid": 1, "f": "-12.5"], snapshot: false)?.feeCNS, "-12.5", "an amount string is kept as it is")
        let fill = try XCTUnwrap(PerplFillEvent(json: ["mkt": 1, "oid": 77, "acc": 10, "l": 2, "p": 816000, "s": 40, "f": "12", "at": ["txid": "AB"]]))
        XCTAssertEqual(fill.isMaker, false)
        XCTAssertEqual(fill.txid, "0xab")
        XCTAssertNil(PerplFillEvent(json: ["mkt": 1, "oid": 77]), "no size")
        let position = try XCTUnwrap(PerplPositionEvent(json: ["pid": 41, "mkt": 1, "sd": 2, "s": 20000, "ep": 816155, "c": "50000000", "lv": 500, "rq": 6, "oid": 77]))
        XCTAssertEqual(position.isLong, false)
        XCTAssertEqual(position.collateralCNS, "50000000")
        XCTAssertNil(PerplPositionEvent(json: ["mkt": 1]))
    }

    func testTheCensusHoldsCountsOnly() throws {
        var census = PerplStreamCensus()
        census.requestsWritten = 31
        census.firstEventCarriedRq = 31
        census.heartbeatsInOrder = 8211
        var other = PerplStreamCensus()
        other.requestsWritten = 1
        other.heartbeatGaps = 2
        census.merge(other)
        XCTAssertEqual(census.requestsWritten, 32)
        XCTAssertEqual(census.heartbeatGaps, 2)
        XCTAssertTrue(census.summary.hasPrefix("perpl census written=32 firstRq=31/0 none12s=0 decided=0 timedOut=0 oid=scid 0/0/0"))
        XCTAssertTrue(census.summary.hasSuffix("hb=8211/2/0/0 cont=0 margin=0/0/0/0/0/0"))
        XCTAssertEqual(try JSONDecoder().decode(PerplStreamCensus.self, from: JSONEncoder().encode(census)), census)
    }

    /// The add-margin counts (p4 spec A.5) merge and log like the others, and a census stored by an earlier build — with
    /// none of the fields added since — still reads, its counts kept.
    func testTheCensusCountsMarginAndReadsAnOlderOne() throws {
        var census = PerplStreamCensus()
        census.marginWritten = 3
        census.marginSt4or10 = 1
        census.marginSt5or6 = 1
        var other = PerplStreamCensus()
        other.marginSt7 = 1
        other.marginPositionWithRq = 2
        other.marginGrowthWithoutRq = 1
        census.merge(other)
        XCTAssertTrue(census.summary.hasSuffix(" margin=3/1/1/1/2/1"), census.summary)
        XCTAssertEqual(try JSONDecoder().decode(PerplStreamCensus.self, from: JSONEncoder().encode(census)), census)
        // Phases 0–3 stored this shape: no margin fields (and an older one fewer still).
        let stored = #"{"requestsWritten":31,"firstEventCarriedRq":30,"heartbeatsInOrder":8211,"foreignReports":2}"#
        let read = try JSONDecoder().decode(PerplStreamCensus.self, from: Data(stored.utf8))
        XCTAssertEqual(read.requestsWritten, 31)
        XCTAssertEqual(read.firstEventCarriedRq, 30)
        XCTAssertEqual(read.heartbeatsInOrder, 8211)
        XCTAssertEqual(read.foreignReports, 2)
        XCTAssertEqual(read.marginWritten, 0)
        XCTAssertEqual(read.heartbeatGaps, 0)
    }

    // MARK: Add margin (p4 spec A.4.3)

    private let margin = PerplSentRequest(accountId: 10, marketId: 1, wireType: 6, lotLNS: 0, kind: .collateral, writtenAt: Date(timeIntervalSince1970: 1_800_000_000))

    /// A margin request is never an order's outcome, and its reports never touch an order's: they attach to its own
    /// request only, by its request id (one without is dropped), never mapping the order id they may carry (I8).
    func testAMarginRequestIsIsolatedFromOrders() {
        let order31 = PerplOpenOrder.Key(marketId: 1, oid: 31)
        var book = PerplOrderLedger(account: 10)
        book.noteSent(limit(), rq: 480)
        book.noteSent(margin, rq: 500)
        _ = book.apply(event(["rq": 480, "mkt": 1, "oid": 31, "t": 1, "st": 2, "os": 100]), at: now)
        XCTAssertEqual(book.requestId(for: order31, accountId: 10), 480)
        let applied = book.apply(event(["rq": 500, "mkt": 1, "oid": 31, "t": 6, "st": 10]), at: now)
        XCTAssertEqual(applied.changed, [500])
        XCTAssertNil(applied.cancelTarget)
        XCTAssertEqual(book.requestId(for: order31, accountId: 10), 480, "the margin's report never takes the order's key")
        XCTAssertNil(book.orderKey(rq: 500, accountId: 10))
        XCTAssertNil(book.outcome(rq: 500, sent: margin, final: true), "never an order's outcome")
        // A later fill of the order still joins the order.
        XCTAssertEqual(book.apply(PerplFillEvent(marketId: 1, orderId: 31, accountId: 10, priceRaw: 800000, sizeRaw: 40, feeCNS: "1"), at: now), [480])
        // A t:6 report without a request id names nothing of its own.
        XCTAssertEqual(book.apply(event(["oid": 31, "mkt": 1, "t": 6, "st": 4]), at: now).changed, [])
        XCTAssertEqual(book.requestId(for: order31, accountId: 10), 480)
        // A position report naming the order (not the margin's request) never reads as the margin moving it.
        _ = book.apply(PerplPositionEvent(json: ["pid": 7, "mkt": 1, "oid": 31, "s": 40])!, at: now)
        XCTAssertFalse(book.sawPositionChange(rq: 500, accountId: 10))
        XCTAssertTrue(book.sawPositionChange(rq: 480, accountId: 10))
    }

    /// The decision table (p4 spec A.4.3): growth under the request wins; a terminal success is added; Canceled or Expired
    /// alone is undecided (never refused); a failure is refused when final at once, or at the end with continuity.
    func testTheMarginOutcomeTable() {
        func outcome(_ events: [[String: Any]], final: Bool = false, grown: BigUInt? = nil) -> PerplCollateralOutcome? {
            var book = PerplOrderLedger(account: 10)
            book.noteSent(margin, rq: 9)
            for json in events { _ = book.apply(event(json), at: now) }
            return book.collateralOutcome(rq: 9, sent: margin, final: final, grown: grown)
        }
        XCTAssertNil(outcome([]), "nothing seen")
        XCTAssertEqual(outcome([["rq": 9, "t": 6, "st": 10]]), .added(deltaCNS: nil))
        XCTAssertEqual(outcome([["rq": 9, "t": 6, "st": 4]]), .added(deltaCNS: nil))
        XCTAssertNil(outcome([["rq": 9, "t": 6, "st": 5]]))
        XCTAssertNil(outcome([["rq": 9, "t": 6, "st": 5]], final: true), "Canceled alone may mean processed: never refused")
        XCTAssertNil(outcome([["rq": 9, "t": 6, "st": 6]], final: true))
        XCTAssertEqual(outcome([["rq": 9, "t": 6, "st": 5]], grown: 10_000_000), .added(deltaCNS: 10_000_000))
        XCTAssertEqual(outcome([["rq": 9, "t": 6, "st": 7, "sr": 36, "fr": 2]]), .refused(PerplOrderReason(status: 7, reason: 36, failure: 2)))
        XCTAssertEqual(outcome([["rq": 9, "t": 6, "st": 7, "sr": 34]]), .refused(PerplOrderReason(status: 7, reason: 34)))
        XCTAssertNil(outcome([["rq": 9, "t": 6, "st": 7, "sr": 15]]), "provisional")
        XCTAssertEqual(outcome([["rq": 9, "t": 6, "st": 7, "sr": 15]], final: true), .refused(PerplOrderReason(status: 7, reason: 15)))
        XCTAssertEqual(outcome([["rq": 9, "t": 6, "st": 7, "fr": 2]], final: true, grown: 10_000_000), .added(deltaCNS: 10_000_000), "growth wins")
        XCTAssertNil(outcome([["rq": 9, "mkt": 2, "t": 6, "st": 10]]), "another request's report under this id")
        XCTAssertNil(outcome([["rq": 9, "t": 6, "r": true]], final: true), "removed without a failure")
        XCTAssertEqual(PerplOrderReason(status: 7, reason: 36, failure: 2).message, "There isn't enough available margin to add to this position.")
    }

    // MARK: 35 Every wait fits the drain

    func testEveryWaitFitsUnderTheDrainCap() {
        XCTAssertLessThan(PerplTimeouts.removal + PerplTimeouts.triggerOutcome + 2, PerplTimeouts.drainOperation)
        XCTAssertLessThan(PerplTimeouts.outcomeWallClock, PerplTimeouts.drainOperation)
        XCTAssertEqual(PerplTimeouts.ack, PerplTimeouts.drainAcks)
        XCTAssertLessThan(PerplTimeouts.ack + PerplTimeouts.marginEvidence, PerplTimeouts.drainOperation, "add margin's wait fits the drain")
        XCTAssertLessThanOrEqual(PerplTimeouts.ordersSnapshot + PerplTimeouts.ack + PerplTimeouts.removal, PerplTimeouts.drainOperation,
                                 "a resting order's cancel: the wait for its socket's list, its ack and its removal fit the drain")
        XCTAssertFalse(PerplOrderLedger.concludesExpiryFromHeartbeat, "no heartbeat-only \"not executed\" in this build")
    }
}
