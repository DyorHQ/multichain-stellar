#if DEBUG
import BigInt
import XCTest
@testable import DyorKit

/// The scripted Perps demo's catalog (p4 spec D, DEBUG only): every scenario's frames are Perpl's for the demo account
/// and market, never a request of the app's own (mt:22, mt:29), and each one, fed to a real scripted client in virtual
/// time — its delays collapsed, its order kept — through the same client calls the sheets make, reaches the state its
/// screen shows: the entry's outcome, its take-profit / stop-loss, the cancels' results, the margin's, the close's
/// evidence, and what a dropped socket does.
@MainActor
final class PerplDemoScriptTests: XCTestCase {
    typealias Script = PerplDemoScript

    /// Every id of p4 spec D.4, in its order.
    static let specIds = [
        "order-filled", "order-rebate", "order-partly-filled", "order-partly-resting", "order-resting", "order-cancelled-elsewhere", "order-expired",
        "order-not-filled", "order-not-filled-leftovers", "order-may-be-armed", "order-failed", "order-refused", "order-provisional-then-filled",
        "order-unconfirmed", "order-unanswered", "order-foreign", "order-tpsl-at-once", "order-tp-cap", "order-tp-not-listed", "order-tp-refused-ack",
        "order-triggered-later", "order-cancelled-later", "status-row",
        "cancel-tpsl-mixed",
        "close-market-filled", "close-partial-25", "close-market-partly", "close-market-not-filled", "close-not-filled-try-again", "close-failed",
        "close-refused-gateway", "close-socket-drop", "close-limit-resting", "close-unconfirmed", "close-unanswered", "close-status-row",
        "margin-added", "margin-added-position-only", "margin-st5-then-position", "margin-st5-only", "margin-chain-only", "margin-growth-without-rq",
        "margin-refused", "margin-provisional-then-added", "margin-refused-gateway", "margin-unanswered", "margin-unconfirmed", "margin-zero",
        "margin-over-available", "margin-dismissed", "margin-dismissed-unconfirmed",
        "cancel-order-cancelled", "cancel-order-filled-first", "cancel-order-expired-first", "cancel-order-still-live", "cancel-order-generic-refusal",
        "cancel-order-refused-ack", "cancel-order-already-gone", "cancel-order-not-confirmed",
        "cards", "cards-cancelling", "cards-order-gone",
    ]

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    // MARK: The catalog

    func testEveryIdIsUniqueAndListedInTheSpec() {
        let ids = Script.scenarios.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "unique")
        XCTAssertEqual(ids, Self.specIds)
        for scenario in Script.scenarios {
            XCTAssertFalse(scenario.title.isEmpty, scenario.id)
            XCTAssertFalse(scenario.expected.isEmpty, scenario.id)
            XCTAssertEqual(Script.scenario(scenario.id), scenario)
        }
    }

    /// Every frame renders to JSON: the prelude's lists and every reply's orders, fills and positions are the demo account's
    /// on the demo market; nothing is a request of the app's own (mt:22) or a sign-in (mt:29).
    func testEveryTemplateRendersAsTheDemoAccountsFrames() throws {
        for scenario in Script.scenarios {
            var frames = scenario.prelude.map { Script.render($0, rq: 501, sn: 1, head: Script.firstHead, serverSn: 50_000, nowMs: 0) }
            for reply in scenario.replies {
                frames += reply.frames.map { Script.render($0.template, rq: 501, sn: 1, head: Script.firstHead, serverSn: 50_000, nowMs: 0) }
                if let ack = Script.ackFrame(reply.ack, sn: 1, serverSn: 50_001) { frames.append(ack) }
            }
            frames.append(Script.render(Script.removal(oid: 31), rq: 0, sn: 0, head: Script.firstHead, serverSn: 0, nowMs: 0))
            for text in frames {
                XCTAssertFalse(text.contains("{rq}") || text.contains("{sn}") || text.contains("{h}") || text.contains("{n}"), "\(scenario.id): \(text)")
                let frame = try XCTUnwrap(Self.json(text), "\(scenario.id): \(text)")
                let mt = try XCTUnwrap(frame["mt"] as? Int, "\(scenario.id): \(text)")
                XCTAssertFalse(mt == 22 || mt == 29, "\(scenario.id): never the app's own request or a sign-in")
                switch mt {
                case 19:
                    let account = try XCTUnwrap((frame["as"] as? [[String: Any]])?.first)
                    XCTAssertEqual(account["id"] as? Int, Script.accountId)
                    XCTAssertEqual(account["fw"] as? Bool, true)
                case 23, 24, 25, 26, 27:
                    for item in try XCTUnwrap(frame["d"] as? [[String: Any]]) {
                        XCTAssertEqual(item["acc"] as? Int, Script.accountId, "\(scenario.id): \(text)")
                        XCTAssertEqual(item["mkt"] as? Int, Script.marketId, "\(scenario.id): \(text)")
                    }
                case 3:
                    XCTAssertEqual(frame["cid"] as? Int, 1, "the ack answers the frame's own sequence")
                default:
                    XCTFail("\(scenario.id): mt \(mt)")
                }
            }
            XCTAssertEqual(scenario.prelude.count, 3, scenario.id)
            XCTAssertNotNil(Self.json(Script.heartbeat(sn: 1001, head: Script.firstHead)))
        }
    }

    func testMatchingAWrittenFrame() {
        let account = Script.accountId
        let ticket = Script.Ticket(kind: .market, takeProfit: 90_000, stopLoss: 75_000)
        let entry = PerplOrders.entry(ticket.input, accountId: account, head: 0)
        let tp = PerplOrders.takeProfit(side: .long, price: 90_000, size: 0.001, market: Script.market, accountId: account, linkedPositionId: nil)
        let sl = PerplOrders.stopLoss(side: .long, price: 75_000, size: 0.001, market: Script.market, accountId: account, linkedPositionId: nil)
        let close = PerplOrders.entry(PerplService.closeInput(market: Script.market, position: Script.position(), size: 0.002, slippageBps: 100), accountId: account, head: 0)
        let margin = PerplOrders.addMargin(perpId: Script.marketId, amountCNS: 10_000_000, accountId: account)
        let cancel = PerplOrders.cancel(perpId: Script.marketId, orderId: 31, accountId: account, head: 0)
        XCTAssertEqual(Script.match(entry.json(rq: 1, sn: 1)), .entry)
        XCTAssertEqual(Script.match(tp.json(rq: 2, sn: 2)), .takeProfit)
        XCTAssertEqual(Script.match(sl.json(rq: 3, sn: 3)), .stopLoss)
        XCTAssertEqual(Script.match(close.json(rq: 4, sn: 4)), .close)
        XCTAssertEqual(Script.match(margin.json(rq: 5, sn: 5)), .margin)
        XCTAssertEqual(Script.match(cancel.json(rq: 6, sn: 6)), .cancel(oid: 31))
        XCTAssertNil(Script.match(["mt": 1, "t": 0]), "the keep-alive ping is never answered")
        XCTAssertEqual(Script.render("{rq}/{sn}/{h}/{n}/{now}", rq: 7, sn: 8, head: 9, serverSn: 10, nowMs: 11), "7/8/9/10/11")
        XCTAssertNil(Script.ackFrame(.none, sn: 1, serverSn: 2), "an unanswered frame gets no ack")
        let nack = try? XCTUnwrap(Self.json(Script.ackFrame(.refused(code: 400, error: "bad \"request\""), sn: 3, serverSn: 4) ?? ""))
        XCTAssertEqual((nack?["status"] as? [String: Any])?["error"] as? String, "bad \"request\"", "Perpl's words, escaped")
    }

    func testTheChainReadsAndTheFixtures() throws {
        let chain = try XCTUnwrap(Script.scenario("margin-chain-only"))
        XCTAssertEqual(chain.chainMargin(afterWriteMs: nil), 32, "before the write: the margin it had")
        XCTAssertEqual(chain.chainMargin(afterWriteMs: 1000), 32)
        XCTAssertEqual(chain.chainMargin(afterWriteMs: 2000), 42, "the 2 s poll sees it")
        XCTAssertEqual(try XCTUnwrap(Script.scenario("margin-st5-only")).chainMargin(afterWriteMs: 10_000), 32, "the chain stays at 32")
        XCTAssertEqual(try XCTUnwrap(Script.scenario("margin-over-available")).available, 18, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Script.scenario("margin-added")).available, 2468, accuracy: 1e-9)
        XCTAssertFalse(try XCTUnwrap(Script.scenario("cancel-tpsl-mixed")).hasPosition)
        let position = Script.position()
        XCTAssertEqual(position.size, 0.002)
        XCTAssertEqual(position.margin, 32)
        XCTAssertNotNil(position.liquidation)
        XCTAssertEqual(Script.position(margin: 42).margin, 42)
    }

    /// `debugAttach` writes nothing until a frame is sent; the prelude signs the client in on the demo account with one-click on.
    func testTheScriptedClientWritesOnlyWhatIsSent() async throws {
        let client = PerplTradeClient.debugScripted()
        XCTAssertTrue(client.isDebugScripted)
        var written: [String] = []
        client.debugAttach { written.append($0) }
        XCTAssertEqual(written, [], "nothing until a frame is sent")
        for frame in try XCTUnwrap(Script.scenario("order-filled")).prelude { client.debugReceive(frame) }
        XCTAssertEqual(written, [], "the prelude is Perpl's, nothing goes back")
        XCTAssertTrue(client.signedIn)
        XCTAssertEqual(client.accountId, Script.accountId)
        XCTAssertTrue(client.forwardingEnabled)
        XCTAssertTrue(client.hasOrdersSnapshot && client.hasPositionsSnapshot)
        XCTAssertEqual(client.openOrders.map(\.oid), [31])
        XCTAssertEqual(client.positions.map(\.pid), [Script.positionId])
        XCTAssertEqual(client.requestId(for: PerplOpenOrder.Key(marketId: Script.marketId, oid: 31)), 480)
        XCTAssertEqual(PerplOpenOrder.streamOrder(for: Script.chainOrder, in: client.openOrders, priceDecimals: Script.market.priceDecimals)?.oid, 31,
                       "the chain order is named by its smart contract order id")
        // A frame sent is written, once; a drop then ends its wait as "outcome unknown" (it may have gone through).
        let cancel = Task { try await client.sendEach([PerplOrders.cancel(perpId: Script.marketId, orderId: 31, accountId: Script.accountId, head: 0)]) }
        for _ in 0..<400 where written.isEmpty { await Task.yield() }
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(Self.json(written[0])?["t"] as? Int, 5)
        XCTAssertEqual(Self.json(written[0])?["rq"] as? Int, 501)
        client.debugDrop()
        let acks = try await cancel.value
        XCTAssertEqual(acks.first?.outcomeUnknown, true)
        XCTAssertFalse(client.signedIn)
    }

    // MARK: Every scenario, driven

    func testEveryScenarioReachesWhatItShows() async throws {
        for scenario in Script.scenarios {
            try await drive(scenario)
        }
    }

    private func drive(_ scenario: Script.Scenario) async throws {
        let wire = DemoWire(scenario)
        XCTAssertTrue(wire.client.signedIn, scenario.id)
        switch scenario.screen {
        case .order(let ticket): try await driveOrder(scenario, ticket, wire)
        case .close(let percent, let limit, let postOnly): try await driveClose(scenario, percent: percent, limit: limit, postOnly: postOnly, wire)
        case .margin(let amount): try await driveMargin(scenario, amount: amount, wire)
        case .cancelOrder: try await driveCancelOrder(scenario, wire)
        case .cancelTriggers: try await driveCancelTriggers(scenario, wire)
        case .cards: try await driveCards(scenario, wire)
        }
    }

    private func outcome(_ wire: DemoWire, _ rq: Int?, final: Bool = false) -> PerplOrderOutcome? {
        guard let rq, let sent = wire.client.sentRequest(rq: rq) else { return nil }
        return wire.client.outcome(rq: rq, sent: sent, final: final)
    }

    /// The order sheet's bracket, as `submitBracket` writes it: the entry with its reserved id, its triggers linked by `tr`.
    private func driveOrder(_ s: Script.Scenario, _ ticket: Script.Ticket, _ wire: DemoWire) async throws {
        let id = s.id
        let account = Script.accountId
        var frames = [PerplOrders.entry(ticket.input, accountId: account, head: 0)]
        if let tp = ticket.takeProfit {
            frames.append(PerplOrders.takeProfit(side: .long, price: tp, size: Script.Ticket.size, market: Script.market, accountId: account, linkedPositionId: nil))
        }
        if let sl = ticket.stopLoss {
            frames.append(PerplOrders.stopLoss(side: .long, price: sl, size: Script.Ticket.size, market: Script.market, accountId: account, linkedPositionId: nil))
        }
        let entryRq = wire.client.reserveRequestId()
        XCTAssertEqual(entryRq, 501, "above the snapshot's lfr")
        frames[0].requestId = entryRq
        for index in frames.indices.dropFirst() { frames[index].linkedRequestId = entryRq }
        let client = wire.client
        let bracket = Task { try await client.placeAll(frames) }
        await wire.settle()
        if s.replies.first(where: { $0.match == .entry })?.ack == Script.Ack.none {
            // Never answered: the triggers wait for the entry's ack (GL-1); a drop ends the wait as "outcome unknown".
            await wire.pump()
            XCTAssertEqual(wire.frames.count, 1, id)
            XCTAssertTrue(client.hasRequestsInFlight, id)
            client.debugDrop()
            do { _ = try await bracket.value; XCTFail(id) } catch let error as PerplTradeError { XCTAssertTrue(error.outcomeUnknown, id) }
            return
        }
        await wire.pump()
        let acks = try await bracket.value
        let entry = outcome(wire, entryRq)
        let tp = acks.count > 1 ? outcome(wire, acks[1].requestId) : nil
        let sl = acks.count > 2 ? outcome(wire, acks[2].requestId) : nil
        func fill(_ o: PerplOrderOutcome?) -> PerplFillSummary? { o?.fill }
        switch id {
        case "order-filled", "order-triggered-later", "order-cancelled-later", "status-row", "order-rebate":
            guard case .filled(let summary)? = entry else { return XCTFail("\(id): \(String(describing: entry))") }
            XCTAssertEqual(summary.filledSizeRaw, 100, id)
            XCTAssertEqual(summary.priceRaw, 816_155, id)
            XCTAssertEqual(summary.feeCNS, id == "order-rebate" ? "-1200" : "28159", id)
            XCTAssertEqual(tp, id == "order-cancelled-later" ? .cancelled(PerplOrderReason(status: 5, reason: 28)) : .armed, id)
            XCTAssertEqual(sl, id == "order-triggered-later" ? .triggered : .armed, id)
            XCTAssertTrue(wire.client.sawPositionChange(rq: entryRq), id)
        case "order-partly-filled":
            guard case .partlyFilled(let summary, rest: .cancelled(let reason))? = entry else { return XCTFail("\(id): \(String(describing: entry))") }
            XCTAssertEqual(summary.filledSizeRaw, 40)
            XCTAssertEqual(reason.reason, 16)
            XCTAssertEqual(tp, .armed)
            XCTAssertEqual(sl, .armed)
        case "order-partly-resting":
            guard case .partlyFilled(let summary, rest: .resting(let oid))? = entry else { return XCTFail("\(id): \(String(describing: entry))") }
            XCTAssertEqual(summary.filledSizeRaw, 40)
            XCTAssertEqual(summary.priceRaw, 817_000)
            XCTAssertEqual(oid, 81)
            XCTAssertTrue(wire.client.openOrders.contains { $0.oid == 81 }, "the rest is on the book")
        case "order-resting":
            XCTAssertEqual(entry, .resting(orderId: 80))
            XCTAssertEqual(tp, .armed)
            XCTAssertEqual(sl, .armed)
            XCTAssertEqual(frames[0].postOnly, true)
        case "order-cancelled-elsewhere":
            XCTAssertEqual(entry, .cancelled(PerplOrderReason(status: 5, reason: 28)))
        case "order-expired":
            XCTAssertEqual(entry, .expired)
        case "order-not-filled", "order-failed":
            if id == "order-failed" {
                XCTAssertEqual(entry, .failed(PerplOrderReason(status: 7, reason: 44, failure: 1)))
            } else {
                guard case .notFilled(let reason)? = entry else { return XCTFail("\(id): \(String(describing: entry))") }
                XCTAssertEqual(reason.reason, 16)
            }
            XCTAssertEqual(tp, .cancelled(PerplOrderReason(status: 5, reason: 28)), "\(id): cancelled with the entry")
            XCTAssertEqual(sl, .cancelled(PerplOrderReason(status: 5, reason: 28)), id)
        case "order-not-filled-leftovers", "order-may-be-armed":
            XCTAssertEqual(entry?.executedNothing, true, id)
            XCTAssertEqual(tp, .armed, id)
            XCTAssertEqual(sl, .armed, id)
            if id == "order-may-be-armed" {
                XCTAssertFalse(wire.client.signedIn, "dropped after the entry's result, before the list check")
            } else {
                // Still listed, named by their requests: the sheet offers to cancel them; the cancels are answered.
                let listed = wire.client.openOrders.filter { [78, 79].contains($0.oid) }
                XCTAssertEqual(listed.count, 2)
                XCTAssertTrue(listed.allSatisfy { wire.client.requestId(for: $0.id) != nil })
                let cancels = Task { try await client.sendEach(listed.map { PerplOrders.cancel(perpId: $0.marketId, orderId: $0.oid, accountId: account, head: 0) }) }
                await wire.settle()
                await wire.pump()
                let acks = try await cancels.value
                for (order, ack) in zip(listed, acks) {
                    XCTAssertEqual(wire.client.cancelResult(of: order.id, cancelRq: try XCTUnwrap(ack.requestId)), .cancelled)
                }
            }
        case "order-refused":
            XCTAssertEqual(acks.count, 1)
            XCTAssertFalse(acks[0].accepted)
            XCTAssertEqual(acks[0].code, 400)
            XCTAssertEqual(acks[0].error, "last exec block already expired")
            XCTAssertNil(entry, "nothing to follow")
        case "order-provisional-then-filled":
            guard case .filled? = entry else { return XCTFail("\(id): \(String(describing: entry))") }
            XCTAssertNil(wire.client.provisionalFailure(rq: entryRq, accountId: account), "the fill replaced the provisional failure")
        case "order-unconfirmed":
            XCTAssertTrue(acks[0].accepted)
            XCTAssertNil(entry, "nothing reported: not confirmed at the deadline")
            XCTAssertNil(outcome(wire, entryRq, final: true))
        case "order-foreign":
            XCTAssertEqual(entry, .unconfirmed(.foreignReport))
        case "order-tpsl-at-once":
            guard case .filled? = entry else { return XCTFail("\(id): \(String(describing: entry))") }
            XCTAssertEqual(tp, .armed)
            XCTAssertEqual(sl, .triggered, "admitted and triggered in one update")
        case "order-tp-cap":
            XCTAssertNil(tp, "a provisional refusal waits for the deadline")
            XCTAssertEqual(outcome(wire, acks[1].requestId, final: true), .failed(PerplOrderReason(status: 7, reason: 24)))
            XCTAssertEqual(sl, .armed)
        case "order-tp-not-listed":
            XCTAssertTrue(acks[1].accepted)
            XCTAssertNil(tp)
            XCTAssertEqual(sl, .armed)
        case "order-tp-refused-ack":
            XCTAssertFalse(acks[1].accepted)
            XCTAssertFalse(acks[1].outcomeUnknown)
            XCTAssertEqual(acks[1].error, "trigger price invalid")
            XCTAssertEqual(sl, .armed, "a refused take-profit never keeps the stop-loss from being sent")
        default:
            XCTFail("\(id) not checked")
        }
        _ = fill(entry)
    }

    /// The Close sheet's close, as `submitClose` writes it: one reduce-only frame, its id reserved, sized by the chip.
    private func driveClose(_ s: Script.Scenario, percent: Int, limit: Double?, postOnly: Bool, _ wire: DemoWire) async throws {
        let id = s.id
        let client = wire.client
        func send() async throws -> (rq: Int, ack: PerplOrderAck?, error: PerplTradeError?) {
            let size = try XCTUnwrap(PerplService.closeFractionSize(positionSize: Script.position().size, lotDecimals: Script.market.lotDecimals, percent: percent))
            let input = PerplService.closeInput(market: Script.market, position: Script.position(), size: size, slippageBps: 100,
                                                kind: limit == nil ? .market : .limit, limitPrice: limit, postOnly: postOnly)
            var frame = PerplOrders.entry(input, accountId: Script.accountId, head: 0)
            let rq = client.reserveRequestId()
            frame.requestId = rq
            let task = Task { try await client.placeAll([frame]) }
            await wire.settle()
            if s.replies.first(where: { $0.match == .close })?.ack == Script.Ack.none {
                await wire.pump()
                XCTAssertTrue(client.hasRequestsInFlight, id)
                client.debugDrop()
            } else {
                await wire.pump()
            }
            do { return (rq, try await task.value.first, nil) } catch let error as PerplTradeError { return (rq, nil, error) }
        }
        if s.steps.contains(.dropSocketBeforeWrite) { client.debugDrop() }
        let first = try await send()
        let result = outcome(wire, first.rq)
        switch id {
        case "close-market-filled", "close-status-row":
            guard case .filled(let summary)? = result else { return XCTFail("\(id): \(String(describing: result))") }
            XCTAssertEqual(summary.filledSizeRaw, 200)
            XCTAssertEqual(summary.priceRaw, 816_100)
            XCTAssertTrue(client.positionClosed(byRequest: first.rq), "\(id): Perpl's report under the close's own request")
            XCTAssertTrue(client.positions.isEmpty)
        case "close-partial-25":
            XCTAssertEqual(wire.frames.last?["s"] as? Int, 50, "25% of 200 lots")
            guard case .filled(let summary)? = result else { return XCTFail("\(id): \(String(describing: result))") }
            XCTAssertEqual(summary.filledSizeRaw, 50)
            XCTAssertFalse(client.positionClosed(byRequest: first.rq))
            XCTAssertTrue(client.sawPositionChange(rq: first.rq))
            XCTAssertEqual(client.positions.first?.sizeRaw, 150, "the rest stays open")
        case "close-market-partly":
            guard case .partlyFilled(let summary, rest: .cancelled)? = result else { return XCTFail("\(id): \(String(describing: result))") }
            XCTAssertEqual(summary.filledSizeRaw, 120)
            XCTAssertEqual(summary.requestedSizeRaw, 200)
        case "close-market-not-filled", "close-not-filled-try-again":
            guard case .notFilled? = result else { return XCTFail("\(id): \(String(describing: result))") }
            XCTAssertEqual(result?.executedNothing, true, "Try Again is offered")
            if id == "close-not-filled-try-again" {
                // A new tap, a new request: the next close reply answers it.
                let second = try await send()
                XCTAssertGreaterThan(second.rq, first.rq)
                guard case .filled? = outcome(wire, second.rq) else { return XCTFail(id) }
                XCTAssertTrue(client.positionClosed(byRequest: second.rq))
            }
        case "close-failed":
            XCTAssertEqual(result, .failed(PerplOrderReason(status: 7, reason: 44, failure: 6)))
        case "close-refused-gateway":
            XCTAssertEqual(first.ack?.accepted, false)
            XCTAssertEqual(first.ack?.code, 400)
        case "close-socket-drop":
            XCTAssertEqual(wire.frames.count, 0, "nothing was written")
            guard case .notSignedIn? = first.error else { return XCTFail("\(id): \(String(describing: first.error))") }
            XCTAssertFalse(first.error?.outcomeUnknown ?? true, "nothing sent: it can be sent again")
        case "close-limit-resting":
            XCTAssertEqual(wire.frames.last?["fl"] as? Int, 1, "post-only")
            XCTAssertEqual(wire.frames.last?["p"] as? Int, 820_000)
            XCTAssertEqual(result, .resting(orderId: 91))
        case "close-unconfirmed":
            XCTAssertEqual(first.ack?.accepted, true)
            XCTAssertNil(result)
        case "close-unanswered":
            XCTAssertEqual(first.error?.outcomeUnknown, true, "written and never answered: it may have gone through")
            XCTAssertNil(result)
        default:
            XCTFail("\(id) not checked")
        }
    }

    /// Add Margin's request, as `PerplTrading.addMargin` writes it: one t:6 frame, then Perpl's evidence.
    private func driveMargin(_ s: Script.Scenario, amount: String, _ wire: DemoWire) async throws {
        let id = s.id
        let client = wire.client
        let amountCNS = PerplService.toCNS(try XCTUnwrap(Double(amount)))
        let frame = PerplOrders.addMargin(perpId: Script.marketId, amountCNS: amountCNS, accountId: Script.accountId)
        switch id {
        case "margin-zero":
            XCTAssertNotNil(PerplOrders.problem(frame), "rounds to zero: refused on the device")
            return
        case "margin-over-available":
            let free = try XCTUnwrap(client.balanceCNS) - (try XCTUnwrap(client.lockedBalanceCNS))
            XCTAssertEqual(free, 18_000_000)
            XCTAssertGreaterThan(amountCNS, free, "more than the account has free: nothing is written")
            return
        default:
            break
        }
        XCTAssertEqual(amountCNS, 10_000_000, id)
        let task = Task { try await client.sendEach([frame]) }
        await wire.settle()
        if s.replies.first?.ack == Script.Ack.none {
            await wire.pump()
            XCTAssertTrue(client.hasRequestsInFlight, id)
            client.debugDrop()
            let ack = try await task.value.first
            XCTAssertEqual(ack?.outcomeUnknown, true, "\(id): written, never answered")
            return
        }
        await wire.pump()
        let acks = try await task.value
        let ack = try XCTUnwrap(acks.first)
        let rq = try XCTUnwrap(ack.requestId)
        let since = try XCTUnwrap(client.sentRequest(rq: rq)).writtenAt
        let result = client.collateralOutcome(rq: rq, final: false)
        switch id {
        case "margin-added", "margin-added-position-only", "margin-st5-then-position", "margin-provisional-then-added":
            XCTAssertEqual(result, .added(deltaCNS: 10_000_000), id)
            XCTAssertEqual(client.collateralAdded(rq: rq), 10_000_000, id)
            XCTAssertTrue(client.openOrders.allSatisfy { $0.typeRaw != 6 }, "a margin report is never an order")
        case "margin-st5-only", "margin-unconfirmed", "margin-dismissed-unconfirmed":
            XCTAssertNil(result, id)
            XCTAssertNil(client.collateralOutcome(rq: rq, final: true), "\(id): never read as refused")
            XCTAssertEqual(s.chainMargin(afterWriteMs: 10_000), 32, "the chain doesn't show it either")
        case "margin-chain-only":
            XCTAssertNil(result)
            XCTAssertEqual(s.chainMargin(afterWriteMs: 2000), 42, "the 2 s chain read shows it")
        case "margin-growth-without-rq":
            XCTAssertNil(result)
            XCTAssertTrue(client.collateralGrowthWithoutRequest(pid: Script.positionId, amountCNS: 10_000_000, since: since))
        case "margin-refused", "margin-dismissed":
            XCTAssertEqual(result, .refused(PerplOrderReason(status: 7, reason: 36, failure: 2)), id)
        case "margin-refused-gateway":
            XCTAssertFalse(ack.accepted)
            XCTAssertFalse(ack.outcomeUnknown)
            XCTAssertEqual(ack.error, "bad request")
        default:
            XCTFail("\(id) not checked")
        }
    }

    /// Cancel Order's cancel, as `cancelResting` sends it (through `cancelAndConfirm`): one cancel by the stream's order id.
    private func driveCancelOrder(_ s: Script.Scenario, _ wire: DemoWire) async throws {
        let id = s.id
        let client = wire.client
        let key = PerplOpenOrder.Key(marketId: Script.marketId, oid: 31)
        if id == "cancel-order-already-gone" {
            await wire.pump()
            XCTAssertFalse(client.openOrders.contains { $0.id == key }, "it left the list before the confirm: nothing is sent")
            XCTAssertNil(client.requestId(for: key))
            return
        }
        let task = Task { try await client.sendEach([PerplOrders.cancel(perpId: Script.marketId, orderId: 31, accountId: Script.accountId, head: 0)]) }
        await wire.settle()
        await wire.pump()
        let acks = try await task.value
        let ack = try XCTUnwrap(acks.first)
        let rq = try XCTUnwrap(ack.requestId)
        let result = client.cancelResult(of: key, cancelRq: rq)
        switch id {
        case "cancel-order-cancelled": XCTAssertEqual(result, .cancelled)
        case "cancel-order-filled-first": XCTAssertEqual(result, .firedFirst)
        case "cancel-order-expired-first": XCTAssertEqual(result, .expiredFirst)
        case "cancel-order-still-live": XCTAssertEqual(result, .refused(PerplOrderReason(status: 7, reason: 36).message))
        case "cancel-order-generic-refusal": XCTAssertEqual(result, .refused(PerplOrderReason(status: 7, reason: 45).message))
        case "cancel-order-refused-ack":
            XCTAssertFalse(ack.accepted)
            XCTAssertEqual(ack.code, 403)
            XCTAssertTrue(client.openOrders.contains { $0.id == key }, "still live")
        case "cancel-order-not-confirmed":
            XCTAssertTrue(ack.accepted)
            XCTAssertNil(result, "still listed: not confirmed at the wait's end")
        default:
            XCTFail("\(id) not checked")
        }
    }

    /// Leftover TP/SL: one cancel each, whatever the others did (`cancelAndConfirm`).
    private func driveCancelTriggers(_ s: Script.Scenario, _ wire: DemoWire) async throws {
        let client = wire.client
        let triggers = client.openOrders
        XCTAssertEqual(triggers.map(\.oid), [40, 41, 42, 43, 44, 45])
        XCTAssertTrue(triggers.allSatisfy(\.isTrigger))
        XCTAssertTrue(client.positions.isEmpty)
        let task = Task { try await client.sendEach(triggers.map { PerplOrders.cancel(perpId: $0.marketId, orderId: $0.oid, accountId: Script.accountId, head: 0) }) }
        await wire.settle()
        await wire.pump()
        let acks = try await task.value
        XCTAssertEqual(acks.count, 6)
        var results: [Int: PerplCancelResult] = [:]
        var undecided: [Int] = []
        for (order, ack) in zip(triggers, acks) {
            if let result = client.cancelResult(of: order.id, cancelRq: try XCTUnwrap(ack.requestId)) { results[order.oid] = result } else { undecided.append(order.oid) }
        }
        XCTAssertEqual(results[40], .cancelled)
        XCTAssertEqual(results[41], .refused(PerplOrderReason(status: 7, reason: 45).message))
        XCTAssertEqual(results[42], .firedFirst)
        XCTAssertEqual(undecided, [43], "still listed: not confirmed at the wait's end")
        XCTAssertEqual(results[44], .alreadyGone)
        XCTAssertEqual(results[45], .expiredFirst)
    }

    private func driveCards(_ s: Script.Scenario, _ wire: DemoWire) async throws {
        let client = wire.client
        XCTAssertEqual(client.openOrders.map(\.oid), [31, 50, 51])
        XCTAssertEqual(client.openOrders.filter(\.isTrigger).map(\.linkedPositionId), [Script.positionId, Script.positionId])
        XCTAssertEqual(client.openOrders.first { $0.oid == 51 }?.isStopLoss, true)
        let targets: [Int]
        switch s.id {
        case "cards": return
        case "cards-cancelling": targets = [31, 51]
        case "cards-order-gone": targets = [31]
        default: return XCTFail("\(s.id) not checked")
        }
        for oid in targets {
            let key = PerplOpenOrder.Key(marketId: Script.marketId, oid: oid)
            let task = Task { try await client.sendEach([PerplOrders.cancel(perpId: Script.marketId, orderId: oid, accountId: Script.accountId, head: 0)]) }
            await wire.settle()
            await wire.pump()
            let acks = try await task.value
            let rq = try XCTUnwrap(acks.first?.requestId)
            XCTAssertEqual(client.cancelResult(of: key, cancelRq: rq), s.id == "cards-order-gone" ? .cancelled : nil, "\(s.id) \(oid)")
        }
    }
}

/// The demo socket in virtual time: the scenario's prelude at once, then what the client writes answered by the scenario's
/// replies, delivered earliest first (ties in the order they were scheduled), with the client's tasks run between
/// deliveries. Steps the client takes part in run here: a drop (after the first write, or before anything) and an order
/// removed from the list; the sheet's own steps (dismissal, Try Again, a card's tap) are the app's.
@MainActor
private final class DemoWire {
    let scenario: PerplDemoScript.Scenario
    let client = PerplTradeClient.debugScripted()
    private(set) var frames: [[String: Any]] = []
    private var queue: [(at: Int, seq: Int, deliver: () -> Void)] = []
    private var seq = 0
    private var now = 0
    private var used: Set<Int> = []
    private var serverSn = 50_000
    private var firstWriteSeen = false

    init(_ scenario: PerplDemoScript.Scenario) {
        self.scenario = scenario
        client.debugAttach { [unowned self] text in self.written(text) }
        for frame in scenario.prelude { client.debugReceive(PerplDemoScript.render(frame, rq: 0, sn: 0, head: PerplDemoScript.firstHead, serverSn: 0, nowMs: 0)) }
        client.debugReceive(PerplDemoScript.heartbeat(sn: PerplDemoScript.snapshotSn + 1, head: PerplDemoScript.firstHead))
        for step in scenario.steps where step.anchor == .start {
            if case .removeOrder(let oid) = step.action {
                schedule(step.afterMs) { [client] in
                    client.debugReceive(PerplDemoScript.render(PerplDemoScript.removal(oid: oid), rq: 0, sn: 0, head: PerplDemoScript.firstHead, serverSn: 0, nowMs: 0))
                }
            }
        }
    }

    private func schedule(_ at: Int, _ deliver: @escaping () -> Void) {
        seq += 1
        queue.append((at, seq, deliver))
    }

    private func written(_ text: String) {
        guard let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        frames.append(frame)
        if !firstWriteSeen {
            firstWriteSeen = true
            for step in scenario.steps where step.anchor == .write && step.action == .drop {
                schedule(now + step.afterMs) { [client] in client.debugDrop() }
            }
        }
        guard let match = PerplDemoScript.match(frame), let sn = frame["sn"] as? Int, let rq = frame["rq"] as? Int,
              let index = scenario.replies.indices.first(where: { !used.contains($0) && scenario.replies[$0].match == match }) else { return }
        used.insert(index)
        let reply = scenario.replies[index]
        serverSn += 1
        if let ack = PerplDemoScript.ackFrame(reply.ack, sn: sn, serverSn: serverSn) {
            schedule(now + reply.ackAfterMs) { [client] in if client.signedIn { client.debugReceive(ack) } }
        }
        for timed in reply.frames {
            serverSn += 1
            let text = PerplDemoScript.render(timed.template, rq: rq, sn: sn, head: PerplDemoScript.firstHead, serverSn: serverSn, nowMs: now + timed.afterMs)
            schedule(now + timed.afterMs) { [client] in if client.signedIn { client.debugReceive(text) } }
        }
    }

    /// Lets the client's tasks run (a resumed ack writes the next frame).
    func settle(_ yields: Int = 40) async {
        for _ in 0..<yields { await Task.yield() }
    }

    /// Delivers everything scheduled, earliest first; done only when nothing more is scheduled after a longer wait.
    func pump() async {
        while true {
            guard let next = queue.min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) else {
                await settle(400)
                if queue.isEmpty { return }
                continue
            }
            queue.removeAll { $0.seq == next.seq }
            now = max(now, next.at)
            next.deliver()
            await settle()
        }
    }
}
#endif
