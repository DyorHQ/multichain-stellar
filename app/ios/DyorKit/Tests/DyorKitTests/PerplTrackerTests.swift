import XCTest
@testable import DyorKit

/// An order the app sent, followed to its result (real-time spec, Phase 1): the notice only evidence can give, the
/// result in words, the watcher that neither races nor repeats an order's own fill notice, when an order settles and
/// what it does then, which order the trade screen's status row shows, and the position watcher's growth. Pure.
final class PerplTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fill(_ filled: Int, of requested: Int = 100, price: Int? = 816_155, fee: String? = "56300", txid: String? = nil) -> PerplFillSummary {
        PerplFillSummary(filledSizeRaw: filled, requestedSizeRaw: requested, priceRaw: price, feeCNS: fee, txid: txid)
    }

    private func reason(_ sr: Int, status: Int = 5, fr: Int? = nil) -> PerplOrderReason { PerplOrderReason(status: status, reason: sr, failure: fr) }

    /// 0.001 BTC (100 lots at 5 decimals) on BTC (price decimals 1).
    private func context(market: Bool = true, limit: Double? = nil, reduces: Bool = false, acknowledged: Bool = true) -> PerplOutcomeText.Context {
        PerplOutcomeText.Context(asset: "BTC", priceDecimals: 1, lotDecimals: 5, requestedSize: 0.001, limitPrice: limit, isMarket: market,
                                 reducesPosition: reduces, slippageBps: 100, acknowledged: acknowledged)
    }

    /// This device's echoes of the helper order's take-profit and stop-loss (`TriggerStore.record`).
    private let tpEcho = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private let slEcho = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!

    private func order(expectedGrowth: Double? = 0.001, closes: PositionSide? = nil, reduceOnly: Bool = false, takeProfit: Bool = false,
                       stopLoss: Bool = false, presented: Bool = false, market: Bool = true) -> PerplTrackedOrder {
        let sent = PerplSentRequest(accountId: 10, marketId: 1, wireType: 1, lotLNS: 100, kind: .entry(ioc: market, sizeRaw: 100), writtenAt: now)
        var order = PerplTrackedOrder(
            id: UUID(), source: .api(accountId: 10, rq: 6), owner: nil, sent: sent, marketId: 1, asset: "BTC", priceDecimals: 1, lotDecimals: 5,
            side: .long, isMarket: market, requestedSize: 0.001, limitPrice: market ? nil : 81_000, reduceOnly: reduceOnly, closes: closes,
            slippageBps: 100, expectedGrowth: expectedGrowth, acknowledged: true, sentAt: now,
            deadline: PerplOutcomeDeadline(ackHead: 100, ttlBlocks: 20, ackAt: now), before: nil, beforeReadAt: now, restingOnSide: false,
            takeProfit: takeProfit ? .init(kind: .takeProfit, rq: 7, price: 90_000, accepted: true, unknown: false, echoId: tpEcho) : nil,
            stopLoss: stopLoss ? .init(kind: .stopLoss, rq: 8, price: 75_000, accepted: true, unknown: false, echoId: slEcho) : nil)
        order.presentedInSheet = presented
        return order
    }

    // MARK: 1 The notice from evidence

    func testTheNoticeComesFromEvidenceNeverFromAnAck() {
        XCTAssertEqual(PerpOrderNotice(evidence: .filled(fill(100))), .filled)
        XCTAssertEqual(PerpOrderNotice(evidence: .observed(.init(side: .long, size: 0.001, price: 81_000, attributable: true))), .filled)
        XCTAssertEqual(PerpOrderNotice(evidence: .partlyFilled(fill(40), rest: .cancelled(reason(16)))), .partlyFilled)
        XCTAssertEqual(PerpOrderNotice(evidence: .resting(orderId: 6)), .placed)
        XCTAssertEqual(PerpOrderNotice(evidence: .notFilled(reason(16))), .notFilled)
        XCTAssertEqual(PerpOrderNotice(evidence: .expired), .notFilled)
        XCTAssertEqual(PerpOrderNotice(evidence: .failed(reason(1, status: 7))), .failed)
        for silent in [PerplOrderOutcome.cancelled(reason(28)), .armed, .triggered, .unconfirmed(.timedOut), .unconfirmed(.connectionLost)] {
            XCTAssertNil(PerpOrderNotice(evidence: silent), "\(silent)")
        }
        XCTAssertEqual(PerpOrderNotice.partlyFilled.title, "Order partly filled")
        XCTAssertEqual(PerpOrderNotice.notFilled.title, "Order not filled")
        XCTAssertEqual(PerpOrderNotice.failed.title, "Order failed")
        // The switch-off path's acknowledgement is never a fill.
        for kind in [OrderKind.market, .limit] { XCTAssertNotEqual(PerpOrderNotice(acknowledged: kind), .filled) }
    }

    // MARK: 2 The result in words

    func testTheResultInWords() {
        let c = context()
        func text(_ o: PerplOrderOutcome, _ c: PerplOutcomeText.Context? = nil) -> PerplOutcomeText { PerplOutcomeText.order(o, c ?? context()) }
        // Filled: the fee, a rebate, no price (never the mark).
        XCTAssertEqual(text(.filled(fill(100))).headline, "Filled 0.001 BTC at 81,615.5 · fee $0.0563")
        XCTAssertEqual(text(.filled(fill(100, fee: "-12000"))).headline, "Filled 0.001 BTC at 81,615.5 · rebate $0.012")
        XCTAssertEqual(text(.filled(fill(100, fee: nil))).headline, "Filled 0.001 BTC at 81,615.5")
        XCTAssertEqual(text(.filled(fill(100, price: nil))).headline, "Filled 0.001 BTC")
        XCTAssertNil(text(.filled(fill(100))).detail)
        XCTAssertEqual(text(.filled(fill(100))).tone, .success)
        // A market order partly filled: the rest was cancelled within its slippage.
        let ioc = text(.partlyFilled(fill(40), rest: .cancelled(reason(16))))
        XCTAssertEqual(ioc.headline, "Partly filled 0.0004 BTC of 0.001 BTC at 81,615.5")
        XCTAssertEqual(ioc.detail, "The rest was cancelled: there wasn't enough on the order book within your 1% slippage.")
        XCTAssertEqual(ioc.tone, .warning)
        XCTAssertEqual(text(.partlyFilled(fill(40, price: nil), rest: .cancelled(reason(28)))).headline, "Partly filled 0.0004 BTC of 0.001 BTC")
        XCTAssertEqual(text(.partlyFilled(fill(40), rest: .cancelled(reason(28)))).detail, "The rest was cancelled.")
        // A limit order: partly filled and resting, then resting.
        let limit = context(market: false, limit: 81_000)
        XCTAssertEqual(text(.partlyFilled(fill(40), rest: .resting(orderId: 6)), limit).detail, "The rest is resting on the book at 81,000.")
        XCTAssertEqual(text(.partlyFilled(fill(40), rest: .expired), limit).detail, "The rest expired before it filled.")
        XCTAssertEqual(text(.resting(orderId: 6), limit).headline, "Resting on the book at 81,000")
        XCTAssertEqual(text(.resting(orderId: 6), limit).tone, .success)
        // Not filled: an order that opens, one that reduces (the slippage named), another reason.
        XCTAssertEqual(text(.notFilled(reason(16))).headline, "Not filled")
        XCTAssertEqual(text(.notFilled(reason(16))).detail, "There wasn't enough on the order book within your 1% slippage, so nothing was opened.")
        XCTAssertEqual(text(.notFilled(reason(16)), context(reduces: true)).detail, "There wasn't enough on the order book within your 1% slippage. Your position is unchanged.")
        XCTAssertEqual(text(.notFilled(reason(46))).detail, "It couldn't fill in full, so nothing was filled. Nothing was opened.")
        XCTAssertEqual(text(.notFilled(reason(16))).tone, .failure)
        // Failed: the reason, fr first; no reason; a reason that already says nothing was placed.
        XCTAssertEqual(text(.failed(reason(44, status: 7, fr: 1))).headline, "Order failed")
        XCTAssertEqual(text(.failed(reason(44, status: 7, fr: 1))).detail, "There isn't enough available margin on your Perpl account for this order. Nothing was opened.")
        XCTAssertEqual(text(.failed(reason(0, status: 7))).detail, "Perpl didn't execute it. Nothing was opened.")
        XCTAssertEqual(text(.failed(reason(32, status: 7))).detail, "Perpl didn't take this order because it clashed with another one from your account. Nothing was placed. Try again.")
        XCTAssertEqual(text(.failed(reason(1, status: 7)), context(reduces: true)).detail, "There isn't enough available balance on your Perpl account. Your position is unchanged.")
        // Expired, cancelled by the user (no failure words), the chain's growth.
        XCTAssertEqual(text(.expired).headline, "Order expired")
        XCTAssertEqual(text(.expired).detail, "It expired before it filled, so nothing was opened.")
        XCTAssertEqual(text(.cancelled(reason(28))).headline, "Order cancelled")
        XCTAssertEqual(text(.cancelled(reason(28))).detail, "It was cancelled before it filled.")
        XCTAssertEqual(text(.cancelled(reason(28))).tone, .neutral)
        let grew = text(.observed(.init(side: .long, size: 0.001, price: 81_650, attributable: true)))
        XCTAssertEqual(grew.headline, "Position grew by 0.001 BTC")
        XCTAssertEqual(grew.detail, "At about 81,650. Perpl's own report for this order hasn't arrived yet.")
        XCTAssertEqual(text(.observed(.init(side: .long, size: 0.001, price: nil, attributable: false))).detail, "Perpl's own report for this order hasn't arrived yet.")
        // Not confirmed: why, when Perpl took the order.
        XCTAssertEqual(text(.unconfirmed(.timedOut)).headline, "Result not confirmed yet")
        XCTAssertEqual(text(.unconfirmed(.timedOut)).detail, "Perpl accepted the order for forwarding but hasn't reported what happened to it yet. Your positions and orders are reloading: check them before placing it again.")
        XCTAssertEqual(text(.unconfirmed(.connectionLost)).detail, "The connection to Perpl dropped before it reported the result. Your positions and orders are reloading: check them before placing it again.")
        XCTAssertEqual(text(.unconfirmed(.foreignReport)).detail, "Perpl reported a different order under this order's request number, so its result can't be shown. Check Positions and Orders before placing it again.")
        // An order Perpl never answered: no detail at all, and nothing that says it was accepted (GL-1, I4).
        for why in [PerplOrderOutcome.Unconfirmed.timedOut, .connectionLost, .foreignReport] {
            let unanswered = text(.unconfirmed(why), context(acknowledged: false))
            XCTAssertNil(unanswered.detail)
            XCTAssertFalse(unanswered.headline.localizedCaseInsensitiveContains("accepted"))
        }
        // Never "Filled" for what didn't fill.
        for o in [PerplOrderOutcome.notFilled(reason(16)), .failed(reason(1, status: 7)), .unconfirmed(.timedOut), .expired, .cancelled(reason(28))] {
            let words = text(o)
            XCTAssertFalse(words.headline.hasPrefix("Filled"), "\(o)")
            XCTAssertFalse(words.headline.contains("filled") && !words.headline.contains("Not filled"), "\(o)")
        }
        // The close sheet speaks of the position.
        XCTAssertEqual(PerplOutcomeText.close(.filled(fill(100)), c).headline, "Closed 0.001 BTC at 81,615.5 · fee $0.0563")
        XCTAssertEqual(PerplOutcomeText.close(.notFilled(reason(16)), c).headline, "Not closed")
        XCTAssertEqual(PerplOutcomeText.close(.notFilled(reason(16)), c).detail, "Nothing on the order book within 1%. Your position is still open. Try again, or close with a limit order.")
        XCTAssertEqual(PerplOutcomeText.close(.partlyFilled(fill(40), rest: .cancelled(reason(16))), c).detail, "The rest wasn't filled within 1%. That part of your position is still open.")
        // A provisional failure is a line under the waiting status, never a headline.
        XCTAssertEqual(PerplOutcomeText.provisional(reason(1, status: 7)),
                       "Perpl reported a problem. There isn't enough available balance on your Perpl account. Waiting for its final answer.")
        XCTAssertEqual(PerplOutcomeText.amount(0.0004, c), "0.0004 BTC")
    }

    // MARK: 3 The watcher and the order's own notice

    func testTheWatcherNeitherRacesNorRepeatsAnOrdersNotice() {
        var fills = PerpExpectedFills()
        let id = UUID()
        let tolerance = 0.000005
        fills.expect(id, perpId: 1, side: .long, growth: 0.001, until: now.addingTimeInterval(12))
        // The order's result isn't in: the watcher waits.
        XCTAssertEqual(fills.decide(perpId: 1, side: .long, growth: 0.001, tolerance: tolerance, now: now.addingTimeInterval(3)), .wait)
        // The order announced its fill: the same growth is quiet, once.
        fills.announced(id, size: 0.001, at: now.addingTimeInterval(4))
        XCTAssertEqual(fills.decide(perpId: 1, side: .long, growth: 0.001, tolerance: tolerance, now: now.addingTimeInterval(5)), .quiet)
        XCTAssertEqual(fills.decide(perpId: 1, side: .long, growth: 0.001, tolerance: tolerance, now: now.addingTimeInterval(20)), .announce, "a new fill")
        // Another side or market is never held.
        XCTAssertEqual(fills.decide(perpId: 1, side: .short, growth: 0.001, tolerance: tolerance, now: now.addingTimeInterval(5)), .announce)

        // The race (I5): the watcher's chain read sees the fill between the fill and the order's settle.
        var race = PerpExpectedFills()
        race.expect(id, perpId: 1, side: .long, growth: 0.001, until: now.addingTimeInterval(12))
        XCTAssertEqual(race.decide(perpId: 1, side: .long, growth: 0.001, tolerance: tolerance, now: now.addingTimeInterval(1)), .wait, "posts nothing yet")
        race.announced(id, size: 0.001, at: now.addingTimeInterval(2))
        XCTAssertEqual(race.decide(perpId: 1, side: .long, growth: 0.001, tolerance: tolerance, now: now.addingTimeInterval(2)), .quiet, "reconsidered: the order said it")

        // An order whose result never came: past its deadline and the grace, the watcher announces.
        var late = PerpExpectedFills()
        late.expect(id, perpId: 1, side: .long, growth: 0.001, until: now.addingTimeInterval(12))
        XCTAssertEqual(late.decide(perpId: 1, side: .long, growth: 0.001, tolerance: tolerance, now: now.addingTimeInterval(13)), .wait)
        XCTAssertEqual(late.decide(perpId: 1, side: .long, growth: 0.001, tolerance: tolerance, now: now.addingTimeInterval(14.5)), .announce)
        // Released (nothing filled, or the order posts no fill notice): nothing waits.
        var released = PerpExpectedFills()
        released.expect(id, perpId: 1, side: .long, growth: 0.001, until: now.addingTimeInterval(12))
        released.release(id)
        XCTAssertEqual(released.decide(perpId: 1, side: .long, growth: 0.001, tolerance: tolerance, now: now.addingTimeInterval(1)), .announce)

        // Netting: held short 0.003, long 0.002 grows nothing, so nothing is expected; the watcher announces any growth.
        XCTAssertNil(PerplPositionEvidence.expectedGrowth(orderSide: .long, size: 0.002, reduceOnly: false, held: (.short, 0.003)))
        var netting = PerpExpectedFills()
        XCTAssertEqual(netting.decide(perpId: 1, side: .long, growth: 0.002, tolerance: tolerance, now: now), .announce)
        // A flip: held short 0.001, long 0.003 grows the long by 0.002, which is the watcher's whole new size.
        let flip = try? XCTUnwrap(PerplPositionEvidence.expectedGrowth(orderSide: .long, size: 0.003, reduceOnly: false, held: (.short, 0.001)))
        XCTAssertEqual(flip ?? 0, 0.002, accuracy: 1e-12)
        var flipped = PerpExpectedFills()
        flipped.expect(id, perpId: 1, side: .long, growth: 0.002, until: now.addingTimeInterval(12))
        flipped.announced(id, size: 0.002, at: now)
        XCTAssertEqual(flipped.decide(perpId: 1, side: .long, growth: 0.002, tolerance: tolerance, now: now.addingTimeInterval(1)), .quiet)
        // Two orders' notices explain one growth.
        var two = PerpExpectedFills()
        let a = UUID(), b = UUID()
        two.expect(a, perpId: 1, side: .long, growth: 0.001, until: now.addingTimeInterval(12))
        two.expect(b, perpId: 1, side: .long, growth: 0.002, until: now.addingTimeInterval(12))
        two.announced(a, size: 0.001, at: now)
        two.announced(b, size: 0.002, at: now)
        XCTAssertEqual(two.decide(perpId: 1, side: .long, growth: 0.003, tolerance: tolerance, now: now.addingTimeInterval(1)), .quiet)
        // The watcher's own notices are remembered by side.
        var watcher = PerpExpectedFills()
        watcher.watcherAnnounced(perpId: 1, side: .long, at: now)
        XCTAssertTrue(watcher.watcherAnnounced(perpId: 1, side: .long, since: now.addingTimeInterval(-1)))
        XCTAssertFalse(watcher.watcherAnnounced(perpId: 1, side: .long, since: now.addingTimeInterval(1)))
        XCTAssertFalse(watcher.watcherAnnounced(perpId: 1, side: .short, since: now.addingTimeInterval(-1)))
    }

    // MARK: 4 Settling

    func testAnEntrySettlesAtOnceWhateverItsTriggersDo() {
        // Filled while both triggers never answered: the entry settles now; its triggers stay "checking".
        var bracket = order(takeProfit: true, stopLoss: true, presented: true)
        let effects = PerplTracker.settleEntry(&bracket, .filled(fill(100)), now: now.addingTimeInterval(2), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(effects, [.announce(.filled, deliverBanner: false), .noteAnnounced(growth: 0.001), .recordActivity(.filled(fill(100))), .reload, .wakeWatcher])
        XCTAssertNil(bracket.takeProfit?.outcome)
        XCTAssertNil(bracket.stopLoss?.outcome)
        XCTAssertTrue(bracket.announced)
        XCTAssertTrue(bracket.outcomeSeenInSheet, "shown in its sheet")
        XCTAssertEqual(bracket.recordedFillRaw, 100)
        // The same result again changes nothing.
        XCTAssertEqual(PerplTracker.settleEntry(&bracket, .filled(fill(100)), now: now.addingTimeInterval(3), notify: true, appActive: true, watcherAnnouncedSinceSent: false), [])

        // The sheet closed or the app in the background: the notice comes as a banner.
        var closed = order()
        XCTAssertEqual(PerplTracker.settleEntry(&closed, .filled(fill(100)), now: now.addingTimeInterval(2), notify: true, appActive: true, watcherAnnouncedSinceSent: false).first,
                       .announce(.filled, deliverBanner: true))
        var background = order(presented: true)
        XCTAssertEqual(PerplTracker.settleEntry(&background, .filled(fill(100)), now: now.addingTimeInterval(2), notify: true, appActive: false, watcherAnnouncedSinceSent: false).first,
                       .announce(.filled, deliverBanner: true))

        // Resting first, a fill five minutes later: the watcher's to announce; the row is written again with its volume.
        var limit = order(market: false)
        let resting = PerplTracker.settleEntry(&limit, .resting(orderId: 6), now: now.addingTimeInterval(2), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(resting, [.releaseExpectation, .recordActivity(.resting(orderId: 6)), .reload, .wakeWatcher])
        XCTAssertTrue(limit.settledFirstAsResting)
        let later = PerplTracker.settleEntry(&limit, .filled(fill(100)), now: now.addingTimeInterval(300), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertFalse(later.contains { if case .announce = $0 { return true }; return false })
        XCTAssertTrue(later.contains(.recordActivity(.filled(fill(100)))))

        // Not confirmed, then a late fill within two minutes: the order's own notice, unless the watcher already gave one.
        var unconfirmed = order()
        XCTAssertEqual(PerplTracker.settleEntry(&unconfirmed, .unconfirmed(.timedOut), now: now.addingTimeInterval(12), notify: true, appActive: true, watcherAnnouncedSinceSent: false),
                       [.releaseExpectation, .reload, .wakeWatcher], "no row and no notice for what isn't known")
        var copy = unconfirmed
        XCTAssertEqual(PerplTracker.settleEntry(&unconfirmed, .filled(fill(100)), now: now.addingTimeInterval(60), notify: true, appActive: true, watcherAnnouncedSinceSent: false).prefix(2),
                       [.announce(.filled, deliverBanner: true), .noteAnnounced(growth: 0.001)])
        let watcherFirst = PerplTracker.settleEntry(&copy, .filled(fill(100)), now: now.addingTimeInterval(60), notify: true, appActive: true, watcherAnnouncedSinceSent: true)
        XCTAssertEqual(watcherFirst, [.releaseExpectation, .recordActivity(.filled(fill(100))), .reload, .wakeWatcher])

        // Cancelled by the user: no notice, the charge is given back (nothing executed).
        var cancelled = order(market: false)
        XCTAssertEqual(PerplTracker.settleEntry(&cancelled, .cancelled(reason(28)), now: now.addingTimeInterval(2), notify: true, appActive: true, watcherAnnouncedSinceSent: false),
                       [.releaseExpectation, .refund, .reload, .wakeWatcher])
        // A final failure of a close: refunded, the noted close voided; once. Its trigger's echo stays until its own result
        // or a live list says it is gone (never on the entry's word alone).
        var failedClose = order(expectedGrowth: nil, closes: .short, takeProfit: true)
        let failed = PerplTracker.settleEntry(&failedClose, .failed(reason(1, status: 7)), now: now.addingTimeInterval(12), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(failed, [.announce(.failed, deliverBanner: true), .releaseExpectation, .refund, .voidUserClose, .reload, .wakeWatcher])
        XCTAssertTrue(failedClose.refunded)
        // Notifications off: no notice, the expectation released.
        var quiet = order()
        XCTAssertEqual(PerplTracker.settleEntry(&quiet, .notFilled(reason(16)), now: now.addingTimeInterval(2), notify: false, appActive: true, watcherAnnouncedSinceSent: false),
                       [.releaseExpectation, .refund, .reload, .wakeWatcher])
        // A reduce-only fill: its own notice, and no growth to note (the watcher never announces a shrink).
        var reduce = order(expectedGrowth: nil, closes: .short, reduceOnly: true)
        let reduced = PerplTracker.settleEntry(&reduce, .filled(fill(100)), now: now.addingTimeInterval(2), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(reduced.first, .announce(.filled, deliverBanner: true))
        XCTAssertFalse(reduced.contains { if case .noteAnnounced = $0 { return true }; return false })
        // A flip notes only the growth past the position it turned around.
        var flip = order(expectedGrowth: 0.0006)
        guard case .noteAnnounced(let grown)? = PerplTracker.settleEntry(&flip, .filled(fill(100)), now: now.addingTimeInterval(2), notify: true, appActive: true,
                                                                          watcherAnnouncedSinceSent: false).dropFirst().first else { return XCTFail("a flip notes its growth") }
        XCTAssertEqual(grown, 0.0006, accuracy: 1e-12)
        // A partial fill that leaves the rest on the book: the order's own notice now, later fills the watcher's.
        var partial = order(market: false)
        let first = PerplTracker.settleEntry(&partial, .partlyFilled(fill(40), rest: .resting(orderId: 6)), now: now.addingTimeInterval(2), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(first.first, .announce(.partlyFilled, deliverBanner: true))
        XCTAssertTrue(partial.settledFirstAsResting)

        // The triggers: cancelled or refused → their OWN echo goes (by its id); armed → kept.
        var children = order(takeProfit: true, stopLoss: true)
        XCTAssertEqual(PerplTracker.settleChild(&children, kind: .takeProfit, .armed, now: now), [])
        XCTAssertEqual(PerplTracker.settleChild(&children, kind: .stopLoss, .failed(reason(57, status: 7)), now: now), [.removeTriggerEcho(.stopLoss, echo: slEcho)])
        XCTAssertEqual(PerplTracker.settleChild(&children, kind: .takeProfit, .cancelled(reason(28)), now: now), [.removeTriggerEcho(.takeProfit, echo: tpEcho)])
        XCTAssertEqual(children.takeProfit?.outcome, .cancelled(reason(28)))
        // An entry that executed nothing: an armed trigger's echo stays (it may still be armed) until a live list read
        // afterwards no longer has it; one still listed keeps it.
        var nothing = order(takeProfit: true)
        _ = PerplTracker.settleEntry(&nothing, .notFilled(reason(16)), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(PerplTracker.settleChild(&nothing, kind: .takeProfit, .armed, now: now), [], "never on \"armed\"")
        XCTAssertEqual(PerplTracker.markCheckedNotListed(&nothing, kind: .takeProfit, now: now), [.removeTriggerEcho(.takeProfit, echo: tpEcho)])
        XCTAssertTrue(nothing.takeProfit?.checkedNotListed == true)
        XCTAssertEqual(PerplTracker.markCheckedNotListed(&nothing, kind: .takeProfit, now: now), [], "once")
        var leftover = order(takeProfit: true)
        _ = PerplTracker.settleEntry(&leftover, .notFilled(reason(16)), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        PerplTracker.markArmedWithoutPosition(&leftover, kind: .takeProfit, now: now)
        XCTAssertEqual(PerplTracker.settleChild(&leftover, kind: .takeProfit, .armed, now: now), [])
        XCTAssertEqual(PerplTracker.markCheckedNotListed(&leftover, kind: .takeProfit, now: now), [], "still listed: kept")
        // Not on an entry that executed something.
        var live = order(takeProfit: true)
        _ = PerplTracker.settleEntry(&live, .filled(fill(100)), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(PerplTracker.markCheckedNotListed(&live, kind: .takeProfit, now: now), [])
    }

    /// The echo an order removes is its own (by id), never another order's of the same kind on that side (GT-1, GT-3):
    /// nothing for a trigger that never had one (refused, never sent), nothing on "armed", and the effect names only that
    /// child's echo.
    func testAnOrderRemovesOnlyItsOwnTriggerEcho() {
        var bracket = order(takeProfit: true, stopLoss: true)
        let effects = PerplTracker.settleChild(&bracket, kind: .stopLoss, .cancelled(reason(28)), now: now)
        XCTAssertEqual(effects, [.removeTriggerEcho(.stopLoss, echo: slEcho)])
        XCTAssertFalse(effects.contains(.removeTriggerEcho(.takeProfit, echo: tpEcho)))
        // Refused (no echo was written): nothing to remove, whatever happens to it or to the entry.
        var refused = order()
        refused.takeProfit = .init(kind: .takeProfit, rq: 7, price: 90_000, accepted: false, unknown: false)
        XCTAssertTrue(refused.takeProfit?.refused == true)
        XCTAssertEqual(PerplTracker.settleEntry(&refused, .notFilled(reason(16)), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
            .filter { if case .removeTriggerEcho = $0 { return true }; return false }, [])
        XCTAssertEqual(PerplTracker.settleChild(&refused, kind: .takeProfit, .cancelled(reason(28)), now: now), [])
        // Never sent (Perpl never answered the entry): no echo, never refused.
        var unsent = order()
        unsent.stopLoss = .init(kind: .stopLoss, rq: nil, price: 75_000, accepted: false, unknown: false, notSent: true)
        XCTAssertFalse(unsent.stopLoss?.refused == true)
        XCTAssertEqual(PerplTracker.settleChild(&unsent, kind: .stopLoss, .cancelled(reason(28)), now: now), [])
        // An executed-nothing entry removes no echo by itself.
        var nothing = order(takeProfit: true, stopLoss: true)
        XCTAssertFalse(PerplTracker.settleEntry(&nothing, .failed(reason(34, status: 7)), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
            .contains { if case .removeTriggerEcho = $0 { return true }; return false })
    }

    /// A take-profit or stop-loss decided inside its own wait right after it was placed is said as such ("triggered at
    /// once", "not placed"); a report minutes later is not.
    func testATriggerKnowsWhetherItWasDecidedInItsOwnWait() {
        var bracket = order(takeProfit: true, stopLoss: true)
        _ = PerplTracker.settleChild(&bracket, kind: .stopLoss, .armed, now: now, duringFollow: true)
        XCTAssertTrue(bracket.stopLoss?.settledDuringFollow == true)
        _ = PerplTracker.settleChild(&bracket, kind: .stopLoss, .triggered, now: now.addingTimeInterval(600))
        XCTAssertFalse(bracket.stopLoss?.settledDuringFollow == true, "fired minutes later")
        _ = PerplTracker.settleChild(&bracket, kind: .takeProfit, .triggered, now: now, duringFollow: true)
        XCTAssertTrue(bracket.takeProfit?.settledDuringFollow == true)
    }

    // MARK: 5 The status row and the ticket

    func testTheStatusRowAndTheTicket() {
        var waiting = order()
        XCTAssertEqual(PerplTracker.bannerOrder([waiting], marketId: 1, now: now)?.id, waiting.id, "waiting, its sheet closed")
        XCTAssertNil(PerplTracker.bannerOrder([waiting], marketId: 2, now: now), "another market")
        waiting.presentedInSheet = true
        XCTAssertNil(PerplTracker.bannerOrder([waiting], marketId: 1, now: now), "shown in its sheet")
        // Settled in its sheet: seen; the sheet closed, it doesn't come back.
        _ = PerplTracker.settleEntry(&waiting, .filled(fill(100)), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        waiting.presentedInSheet = false
        XCTAssertNil(PerplTracker.bannerOrder([waiting], marketId: 1, now: now))
        // A later change after the sheet closed shows again.
        var resting = order(market: false)
        resting.presentedInSheet = true
        _ = PerplTracker.settleEntry(&resting, .resting(orderId: 6), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        resting.presentedInSheet = false
        XCTAssertNil(PerplTracker.bannerOrder([resting], marketId: 1, now: now))
        _ = PerplTracker.settleEntry(&resting, .partlyFilled(fill(40), rest: .resting(orderId: 6)), now: now.addingTimeInterval(60), notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(PerplTracker.bannerOrder([resting], marketId: 1, now: now.addingTimeInterval(61))?.id, resting.id)
        // A success leaves after 8 s; a warning stays until dismissed.
        var success = order()
        _ = PerplTracker.settleEntry(&success, .filled(fill(100)), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertNotNil(PerplTracker.bannerOrder([success], marketId: 1, now: now.addingTimeInterval(7)))
        XCTAssertNil(PerplTracker.bannerOrder([success], marketId: 1, now: now.addingTimeInterval(8)))
        var warning = order()
        _ = PerplTracker.settleEntry(&warning, .unconfirmed(.timedOut), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertNotNil(PerplTracker.bannerOrder([warning], marketId: 1, now: now.addingTimeInterval(3600)))
        warning.bannerDismissed = true
        XCTAssertNil(PerplTracker.bannerOrder([warning], marketId: 1, now: now.addingTimeInterval(3600)))
        // The newest qualifying order.
        let older = order()
        var newer = PerplTrackedOrder(id: UUID(), source: .api(accountId: 10, rq: 9), owner: nil, sent: older.sent, marketId: 1, asset: "BTC", priceDecimals: 1, lotDecimals: 5,
                                      side: .short, isMarket: true, requestedSize: 0.001, limitPrice: nil, reduceOnly: false, closes: nil, slippageBps: 100,
                                      expectedGrowth: 0.001, acknowledged: true, sentAt: now.addingTimeInterval(5), deadline: nil, before: nil, beforeReadAt: nil, restingOnSide: false)
        newer.provisional = reason(1, status: 7)
        XCTAssertEqual(PerplTracker.bannerOrder([older, newer], marketId: 1, now: now.addingTimeInterval(6))?.id, newer.id)

        // A success whose take-profit or stop-loss isn't known to be live (refused, unanswered, never sent) never leaves by
        // itself: the position may be unprotected.
        for child in [PerplTrackedOrder.Child(kind: .stopLoss, rq: 8, price: 75_000, accepted: false, unknown: false),
                      .init(kind: .stopLoss, rq: 8, price: 75_000, accepted: false, unknown: true),
                      .init(kind: .stopLoss, rq: nil, price: 75_000, accepted: false, unknown: false, notSent: true)] {
            var unprotected = order()
            unprotected.stopLoss = child
            XCTAssertTrue(unprotected.hasTriggerWarning)
            _ = PerplTracker.settleEntry(&unprotected, .filled(fill(100)), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
            XCTAssertEqual(PerplTracker.bannerOrder([unprotected], marketId: 1, now: now.addingTimeInterval(3600))?.id, unprotected.id, "\(child)")
            unprotected.bannerDismissed = true
            XCTAssertNil(PerplTracker.bannerOrder([unprotected], marketId: 1, now: now.addingTimeInterval(3600)))
        }
        XCTAssertFalse(order(takeProfit: true, stopLoss: true).hasTriggerWarning, "both accepted")
        // While it waits, it shows (and so does its warning).
        var waitingUnprotected = order()
        waitingUnprotected.takeProfit = .init(kind: .takeProfit, rq: 7, price: 90_000, accepted: false, unknown: false)
        XCTAssertEqual(PerplTracker.bannerOrder([waitingUnprotected], marketId: 1, now: now)?.id, waitingUnprotected.id)

        // A success settled after its sheet closed: its take-profit changing hours later never brings it back.
        var settledLongAgo = order(takeProfit: true)
        _ = PerplTracker.settleEntry(&settledLongAgo, .filled(fill(100)), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(settledLongAgo.entryChangedAt, now)
        _ = PerplTracker.settleChild(&settledLongAgo, kind: .takeProfit, .triggered, now: now.addingTimeInterval(7200))
        XCTAssertEqual(settledLongAgo.lastChangeAt, now.addingTimeInterval(7200))
        XCTAssertNil(PerplTracker.bannerOrder([settledLongAgo], marketId: 1, now: now.addingTimeInterval(7201)), "timed out from the entry's settle")

        // Done clears the ticket unless the order provably executed nothing.
        XCTAssertTrue(PerplTracker.clearsTicket(nil))
        XCTAssertTrue(PerplTracker.clearsTicket(.filled(fill(100))))
        XCTAssertTrue(PerplTracker.clearsTicket(.partlyFilled(fill(40), rest: .cancelled(reason(16)))))
        XCTAssertTrue(PerplTracker.clearsTicket(.resting(orderId: 6)))
        XCTAssertTrue(PerplTracker.clearsTicket(.unconfirmed(.timedOut)))
        XCTAssertTrue(PerplTracker.clearsTicket(.observed(.init(side: .long, size: 0.001, price: nil, attributable: false))))
        for nothing in [PerplOrderOutcome.notFilled(reason(16)), .failed(reason(1, status: 7)), .expired, .cancelled(reason(28))] {
            XCTAssertFalse(PerplTracker.clearsTicket(nothing), "\(nothing)")
        }
    }

    /// A tracked order is stored and read back whole (it outlives the app: `PerplPendingOrderStore`).
    func testATrackedOrderRoundTrips() throws {
        var tracked = order(takeProfit: true)
        tracked.entry = .partlyFilled(fill(40), rest: .resting(orderId: 6))
        tracked.provisional = reason(1, status: 7)
        tracked.expectedSince = now.addingTimeInterval(-2)
        tracked.entryChangedAt = now
        tracked.stopLoss = .init(kind: .stopLoss, rq: nil, price: 75_000, accepted: false, unknown: false, notSent: true)
        tracked.takeProfit?.checkedNotListed = true
        tracked.takeProfit?.settledDuringFollow = true
        let data = try JSONEncoder().encode([tracked])
        XCTAssertEqual(try JSONDecoder().decode([PerplTrackedOrder].self, from: data), [tracked])

        // A record stored before the new fields existed still reads, each with its default.
        var legacy = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(order(takeProfit: true))) as? [String: Any])
        legacy["expectedSince"] = nil
        legacy["entryChangedAt"] = nil
        var child = try XCTUnwrap(legacy["takeProfit"] as? [String: Any])
        for field in ["notSent", "echoId", "checkedNotListed", "settledDuringFollow", "armedWithoutPosition"] { child[field] = nil }
        legacy["takeProfit"] = child
        let read = try JSONDecoder().decode(PerplTrackedOrder.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(read.expectedSince)
        XCTAssertNil(read.entryChangedAt)
        XCTAssertEqual(read.noticeSince, read.sentAt)
        XCTAssertEqual(read.takeProfit?.notSent, false)
        XCTAssertNil(read.takeProfit?.echoId)
        XCTAssertEqual(read.takeProfit?.checkedNotListed, false)
        XCTAssertEqual(read.takeProfit?.settledDuringFollow, false)
        XCTAssertEqual(read.takeProfit?.armedWithoutPosition, false)
    }

    /// A close from the position's Close sheet (p4 spec A.4.1) is stored with its purpose, a record stored before it
    /// existed reads as a ticket order, and its result is decided exactly as a reduce-only order's: no expected growth, the
    /// noted close voided when nothing executed.
    func testACloseIsTrackedAsAReduceOnlyOrderWithItsPurpose() throws {
        var close = order(expectedGrowth: nil, closes: .long, reduceOnly: true)
        close.purpose = .close(wholePosition: true)
        XCTAssertTrue(close.isClose)
        XCTAssertEqual(try JSONDecoder().decode(PerplTrackedOrder.self, from: JSONEncoder().encode(close)), close)
        var partial = close
        partial.purpose = .close(wholePosition: false)
        XCTAssertEqual(try JSONDecoder().decode(PerplTrackedOrder.self, from: JSONEncoder().encode(partial)).purpose, .close(wholePosition: false))

        var legacy = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(close)) as? [String: Any])
        legacy["purpose"] = nil
        let read = try JSONDecoder().decode(PerplTrackedOrder.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(read.purpose)
        XCTAssertFalse(read.isClose)

        for outcome: PerplOrderOutcome in [.filled(fill(100)), .partlyFilled(fill(40), rest: .cancelled(reason(16))), .notFilled(reason(16)),
                                           .failed(reason(44, status: 7, fr: 6)), .resting(orderId: 90), .unconfirmed(.timedOut)] {
            var asClose = close
            var asReduceOnly = order(expectedGrowth: nil, closes: .long, reduceOnly: true)
            let closeEffects = PerplTracker.settleEntry(&asClose, outcome, now: now, notify: true, appActive: true, watcherAnnouncedSinceSent: false)
            let reduceEffects = PerplTracker.settleEntry(&asReduceOnly, outcome, now: now, notify: true, appActive: true, watcherAnnouncedSinceSent: false)
            XCTAssertEqual(closeEffects, reduceEffects, "\(outcome)")
        }
        var nothing = close
        XCTAssertTrue(PerplTracker.settleEntry(&nothing, .notFilled(reason(16)), now: now, notify: true, appActive: true, watcherAnnouncedSinceSent: false)
                        .contains(.voidUserClose))
        // Its result is said of the position.
        XCTAssertEqual(PerplOutcomeText.close(.notFilled(reason(16)), close.textContext).headline, PerplOutcomeText.notClosedHeadline)
    }

    // MARK: 5b Finality, attribution and correction

    /// A decided result is final: a lagging history or a late report never replaces a fill (no refund, no voided close,
    /// no second row); a result that can still change (resting, not confirmed, a growth on the chain) may be replaced.
    func testAFinalResultIsNeverReplaced() {
        var filled = order(closes: .short, takeProfit: true)
        _ = PerplTracker.settleEntry(&filled, .filled(fill(100)), now: now, notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(PerplTracker.settleEntry(&filled, .partlyFilled(fill(40), rest: .cancelled(reason(16))), now: now.addingTimeInterval(5), notify: true,
                                                appActive: true, watcherAnnouncedSinceSent: false), [])
        XCTAssertEqual(PerplTracker.settleEntry(&filled, .failed(reason(1, status: 7)), now: now.addingTimeInterval(5), notify: true,
                                                appActive: true, watcherAnnouncedSinceSent: false), [], "never a refund for a fill")
        XCTAssertEqual(filled.entry, .filled(fill(100)))
        XCTAssertFalse(filled.refunded)
        for final in [PerplOrderOutcome.notFilled(reason(16)), .failed(reason(1, status: 7)), .expired, .cancelled(reason(28)),
                      .partlyFilled(fill(40), rest: .cancelled(reason(16)))] {
            var decided = order()
            _ = PerplTracker.settleEntry(&decided, final, now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
            XCTAssertEqual(PerplTracker.settleEntry(&decided, .filled(fill(100)), now: now.addingTimeInterval(1), notify: false, appActive: true,
                                                    watcherAnnouncedSinceSent: false), [], "\(final)")
        }
        // What can still change still does.
        var resting = order(market: false)
        _ = PerplTracker.settleEntry(&resting, .resting(orderId: 6), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertFalse(PerplTracker.settleEntry(&resting, .filled(fill(100)), now: now.addingTimeInterval(60), notify: false, appActive: true,
                                                watcherAnnouncedSinceSent: false).isEmpty)
        var unconfirmed = order()
        _ = PerplTracker.settleEntry(&unconfirmed, .unconfirmed(.timedOut), now: now, notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertFalse(PerplTracker.settleEntry(&unconfirmed, .notFilled(reason(16)), now: now.addingTimeInterval(20), notify: false, appActive: true,
                                                watcherAnnouncedSinceSent: false).isEmpty)
    }

    /// A growth on the chain another order may have made is never "Order filled" for this one, and the watcher's note
    /// isn't spent on it; one only this order explains still is.
    func testAGrowthThisOrderCantClaimIsNeverAnnounced() {
        let shared = PerplPositionEvidence.Growth(side: .long, size: 0.001, price: 81_000, attributable: false)
        XCTAssertNil(PerpOrderNotice(evidence: .observed(shared)))
        var unclaimed = order()
        let effects = PerplTracker.settleEntry(&unclaimed, .observed(shared), now: now.addingTimeInterval(14), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertFalse(effects.contains { if case .announce = $0 { return true }; return false })
        XCTAssertFalse(effects.contains { if case .noteAnnounced = $0 { return true }; return false })
        XCTAssertTrue(effects.contains(.releaseExpectation))
        XCTAssertFalse(unclaimed.announced)
        // Perpl's own fill later is the order's first notice.
        let later = PerplTracker.settleEntry(&unclaimed, .filled(fill(100)), now: now.addingTimeInterval(30), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(later.prefix(2), [.announce(.filled, deliverBanner: true), .noteAnnounced(growth: 0.001)])

        let own = PerplPositionEvidence.Growth(side: .long, size: 0.001, price: 81_000, attributable: true)
        var claimed = order()
        let ownEffects = PerplTracker.settleEntry(&claimed, .observed(own), now: now.addingTimeInterval(14), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(ownEffects.prefix(2), [.announce(.filled, deliverBanner: true), .noteAnnounced(growth: 0.001)])
    }

    /// Volume and "Order filled" from a growth on the chain are taken back when Perpl says the order executed nothing:
    /// the row is written again without volume, and a second notice says it didn't fill.
    func testAGrowthPerplContradictsIsCorrected() {
        let own = PerplPositionEvidence.Growth(side: .long, size: 0.001, price: 81_000, attributable: true)
        var tracked = order()
        _ = PerplTracker.settleEntry(&tracked, .unconfirmed(.timedOut), now: now.addingTimeInterval(12), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        let observed = PerplTracker.settleEntry(&tracked, .observed(own), now: now.addingTimeInterval(20), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertTrue(observed.contains(.recordActivity(.observed(own))))
        XCTAssertNotNil(PerplOrderOutcome.observed(own).volumeUSD(priceDecimals: 1, lotDecimals: 5), "the row carried volume")
        let corrected = PerplTracker.settleEntry(&tracked, .notFilled(reason(16)), now: now.addingTimeInterval(40), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertTrue(corrected.contains(.announce(.notFilled, deliverBanner: true)), "the user was told it filled")
        XCTAssertTrue(corrected.contains(.recordActivity(.notFilled(reason(16)))), "the row again, with no volume")
        XCTAssertNil(PerplOrderOutcome.notFilled(reason(16)).volumeUSD(priceDecimals: 1, lotDecimals: 5))
        XCTAssertTrue(corrected.contains(.refund))
        // Notifications off: the row is still corrected, no notice.
        var quiet = order()
        _ = PerplTracker.settleEntry(&quiet, .observed(own), now: now.addingTimeInterval(20), notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        let quietCorrection = PerplTracker.settleEntry(&quiet, .cancelled(reason(28)), now: now.addingTimeInterval(40), notify: false, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertTrue(quietCorrection.contains(.recordActivity(.cancelled(reason(28)))))
        XCTAssertFalse(quietCorrection.contains { if case .announce = $0 { return true }; return false })
        // Never a row for a nothing-executed that replaces no growth.
        var plain = order()
        XCTAssertFalse(PerplTracker.settleEntry(&plain, .notFilled(reason(16)), now: now, notify: true, appActive: true, watcherAnnouncedSinceSent: false)
            .contains { if case .recordActivity = $0 { return true }; return false })
    }

    /// The order's own fill notice and the watcher's never both go out: whichever window, a fill the watcher announced on
    /// that side since the watcher started waiting for the order keeps the order quiet; the window counts from that start
    /// (before the frames went out, or before the wallet signed), not from the write or the receipt.
    func testTheOrdersNoticeWindowStartsWithTheWatchersWait() {
        var inWindow = order()
        XCTAssertEqual(PerplTracker.settleEntry(&inWindow, .filled(fill(100)), now: now.addingTimeInterval(2), notify: true, appActive: true, watcherAnnouncedSinceSent: true),
                       [.releaseExpectation, .recordActivity(.filled(fill(100))), .reload, .wakeWatcher], "the watcher said it first")
        XCTAssertFalse(inWindow.announced)
        // An order whose watcher wait began 100 s before its send (its deadline is 12 s after the send): 25 s after the
        // send is 125 s after the wait began, past the late window; 15 s after it is still within it. Counted from the
        // send alone, both would be.
        var waited = order()
        waited.expectedSince = now.addingTimeInterval(-100)
        XCTAssertEqual(waited.noticeSince, now.addingTimeInterval(-100))
        var late = waited
        XCTAssertFalse(PerplTracker.settleEntry(&late, .filled(fill(100)), now: now.addingTimeInterval(25), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
            .contains { if case .announce = $0 { return true }; return false })
        var soon = waited
        XCTAssertTrue(PerplTracker.settleEntry(&soon, .filled(fill(100)), now: now.addingTimeInterval(15), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
            .contains(.announce(.filled, deliverBanner: true)))
        var fromTheSend = order()
        XCTAssertTrue(PerplTracker.settleEntry(&fromTheSend, .filled(fill(100)), now: now.addingTimeInterval(25), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
            .contains(.announce(.filled, deliverBanner: true)))
    }

    /// The chain's growth is read as an order's only while its own result could still be arriving, and never for an
    /// order read back from the store.
    func testTheChainIsReadOnlyWhileTheOrdersResultCouldArrive() {
        let tracked = order() // deadline 12 s after the send
        XCTAssertTrue(PerplTracker.mayReadChainGrowth(tracked, now: now.addingTimeInterval(20), loadedFromDisk: false, window: 120))
        XCTAssertTrue(PerplTracker.mayReadChainGrowth(tracked, now: now.addingTimeInterval(132), loadedFromDisk: false, window: 120))
        XCTAssertFalse(PerplTracker.mayReadChainGrowth(tracked, now: now.addingTimeInterval(133), loadedFromDisk: false, window: 120))
        XCTAssertFalse(PerplTracker.mayReadChainGrowth(tracked, now: now.addingTimeInterval(600), loadedFromDisk: false, window: 120), "the 10-minute reconcile")
        XCTAssertFalse(PerplTracker.mayReadChainGrowth(tracked, now: now.addingTimeInterval(1), loadedFromDisk: true, window: 120), "never after a relaunch")
    }

    /// A wallet-signed order (real-time spec §6.3): followed under its transaction's hash with what finds its request in
    /// the receipt; stored and read back whole, and a record stored before the field existed still reads. Its fill within
    /// its 90 s window is its own to announce, with the growth the watcher then keeps quiet about; nothing filled is
    /// announced, voids the close it was noted as, and has no row of its own here (the sheet writes it, no volume).
    func testAWalletSignedOrderIsFollowedFromItsReceipt() throws {
        let hash = Data(repeating: 0xab, count: 32)
        func onChain(closes: PositionSide? = nil, expectedGrowth: Double? = 0.001) -> PerplTrackedOrder {
            var order = PerplTrackedOrder(
                id: UUID(), source: .onChain(hash: hash), owner: nil, sent: nil, marketId: 1, asset: "BTC", priceDecimals: 1, lotDecimals: 5,
                side: .long, isMarket: true, requestedSize: 0.001, limitPrice: nil, reduceOnly: false, closes: closes, slippageBps: 100,
                expectedGrowth: expectedGrowth, acknowledged: false, sentAt: now, deadline: PerplOutcomeDeadline(ackHead: nil, ttlBlocks: nil, ackAt: now, cap: 90),
                before: nil, beforeReadAt: nil, restingOnSide: false, receiptKey: .init(accountId: 10, descId: 1925))
            order.presentedInSheet = true
            return order
        }
        let tracked = onChain()
        XCTAssertTrue(tracked.isOnChain)
        XCTAssertFalse(order().isOnChain)
        XCTAssertNil(order().receiptKey)
        let data = try JSONEncoder().encode([tracked])
        XCTAssertEqual(try JSONDecoder().decode([PerplTrackedOrder].self, from: data), [tracked])
        // A record written before receiptKey existed reads back without one.
        var legacy = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(order())) as? [String: Any])
        legacy["receiptKey"] = nil
        XCTAssertNil(try JSONDecoder().decode(PerplTrackedOrder.self, from: JSONSerialization.data(withJSONObject: legacy)).receiptKey)

        // Filled 40 s after it was sent: inside its 90 s window, announced by the order (the sheet is open: no banner).
        var filled = tracked
        let effects = PerplTracker.settleEntry(&filled, .filled(fill(100)), now: now.addingTimeInterval(40), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertEqual(effects, [.announce(.filled, deliverBanner: false), .noteAnnounced(growth: 0.001), .recordActivity(.filled(fill(100))), .reload, .wakeWatcher])
        XCTAssertTrue(filled.outcomeSeenInSheet)

        // Nothing filled: the notice, the noted close voided, no row from the tracker.
        var nothing = onChain(closes: .short, expectedGrowth: nil)
        let none = PerplTracker.settleEntry(&nothing, .notFilled(reason(16)), now: now.addingTimeInterval(2), notify: true, appActive: true, watcherAnnouncedSinceSent: false)
        XCTAssertTrue(none.contains(.announce(.notFilled, deliverBanner: false)))
        XCTAssertTrue(none.contains(.voidUserClose))
        XCTAssertFalse(none.contains { if case .recordActivity = $0 { return true }; return false })
        XCTAssertFalse(PerplTracker.clearsTicket(nothing.entry), "nothing executed: the ticket keeps it")

        // A receipt that can't be read: "not confirmed", the expectation released, no notice and no row.
        var unread = tracked
        XCTAssertEqual(PerplTracker.settleEntry(&unread, .unconfirmed(.timedOut), now: now.addingTimeInterval(2), notify: true, appActive: true, watcherAnnouncedSinceSent: false),
                       [.releaseExpectation, .reload, .wakeWatcher])
        XCTAssertNil(PerplOutcomeText.order(.unconfirmed(.timedOut), unread.textContext).detail, "never \"Perpl accepted the order\": Perpl never had it")
        XCTAssertTrue(PerplTracker.clearsTicket(unread.entry))
    }

    // MARK: 6 The watcher's growth

    func testThePositionWatcherSaysHowMuchEachPositionGrew() {
        func position(_ side: PositionSide, _ size: Double) -> PerpPosition {
            PerpPosition(perpId: 1, symbol: "BTC", side: side, size: size, entry: 81_000, mark: 81_000, margin: 10, unrealized: 0, premium: 0, leverage: 2, liquidation: nil, notional: size * 81_000)
        }
        var watch = PerpPositionWatch()
        _ = watch.update([], stillOpen: [])
        XCTAssertEqual(watch.update([position(.long, 0.002)], stillOpen: [1]).growth, [1: 0.002], "new: its whole size")
        XCTAssertEqual(watch.update([position(.long, 0.005)], stillOpen: [1]).growth[1] ?? 0, 0.003, accuracy: 1e-12)
        XCTAssertEqual(watch.update([position(.short, 0.001)], stillOpen: [1]).growth, [1: 0.001], "flipped: its whole size")
        XCTAssertEqual(watch.update([position(.short, 0.001)], stillOpen: [1]).growth, [:])
    }

    // MARK: 7 The order's window

    func testTheContextGivesTheOrdersWindow() {
        // A context without `order_ttl_blocks` counts Perpl's 20 blocks.
        let deadline = PerplOutcomeDeadline(ackHead: 100, ttlBlocks: nil, ackAt: now)
        XCTAssertEqual(deadline.block, 125)
        XCTAssertEqual(PerplOutcomeDeadline(ackHead: 100, ttlBlocks: 20, ackAt: now).block, 125)
    }
}
