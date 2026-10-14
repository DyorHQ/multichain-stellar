import XCTest
@testable import DyorKit

/// The app's wiring of an order's real outcome (real-time spec, Phase 1), read from its sources: the live sheet records
/// and announces nothing at the acknowledgement (the tracker does, at the outcome), an order's Activity row carries
/// volume only from what filled, the order button shows only before anything was sent, every sent entry is followed —
/// one Perpl never answered included — under background time, and the switch is read at the tap.
final class PerpsOutcomeWiringTests: XCTestCase {
    private func squeeze(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// A DyorKit source file, by path relative to `Sources/DyorKit`.
    private func kitSource(_ path: String) throws -> String {
        var kit = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { kit.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit
        return try String(contentsOf: kit.appendingPathComponent("Sources/DyorKit").appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of the function that starts at `signature`, up to its closing brace at the indentation it opened at.
    private func function(_ signature: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), signature)
        let line = text[..<start.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let indent = String(line.prefix { $0 == " " })
        let end = try XCTUnwrap(text.range(of: "\n" + indent + "}\n", range: start.upperBound..<text.endIndex), signature)
        return String(text[start.lowerBound..<end.upperBound])
    }

    func testTheLiveSheetRecordsAndAnnouncesOnlyAtTheOutcome() throws {
        let trade = try DocsLinksTests.appSource("Perps/PerpTradeView.swift")
        let live = try function("private func place(approval: MeraSession.StepUp? = nil) async {", in: trade)
        XCTAssertFalse(live.contains("Activity.record"), "no row at the acknowledgement")
        XCTAssertFalse(live.contains("Notifications."), "no notice at the acknowledgement")
        let legacy = try function("private func placeLegacy(approval: MeraSession.StepUp? = nil) async {", in: trade)
        XCTAssertTrue(legacy.contains("usd: input.size * market.mark"), "the switch-off sheet, as today")
        XCTAssertEqual(trade.components(separatedBy: "usd: input.size * market.mark").count - 1, 1, "only in placeLegacy")

        // Every accepted entry is followed, and so is one Perpl never answered (it may be live), whatever the socket.
        let squeezedLive = squeeze(live)
        XCTAssertTrue(squeezedLive.contains("guard result.entry, let tracking = result.tracking else {"))
        XCTAssertTrue(squeezedLive.contains("let id = perplTrading.track(tracking, input: input,"))
        let unanswered = try XCTUnwrap(squeezedLive.range(of: "} catch let unanswered as PerplTrading.EntryUnanswered {"))
        let catchBody = String(squeezedLive[unanswered.upperBound...].prefix(600))
        XCTAssertTrue(catchBody.contains("onSent() let id = perplTrading.track(unanswered.tracking, input: input,"), "I7: always tracked")
        XCTAssertFalse(catchBody.contains("signedIn"), "never conditional on the socket")
        XCTAssertFalse(live.contains("submit(") || live.contains("resend"), "nothing is resent from the sheet")

        // The order button only before anything was sent; the switch is read at the tap with the path.
        let sheet = squeeze(String(trade[try XCTUnwrap(trade.range(of: "struct AuthedOrderSheet: View {")).lowerBound...]))
        XCTAssertTrue(sheet.contains("switch phase { case .review, .failed: PrimaryButton(title: scopeAssessment?.needsFaceID == true"))
        XCTAssertEqual(sheet.components(separatedBy: "PrimaryButton(title: scopeAssessment?.needsFaceID == true").count - 1, 1)
        XCTAssertTrue(sheet.contains(".interactiveDismissDisabled(phase == .sending)"))
        XCTAssertTrue(sheet.contains("onDone(PerplTracker.clearsTicket("), "a result that executed nothing keeps the ticket")
        let ticket = squeeze(trade)
        XCTAssertTrue(ticket.contains("authedOrderAccount = (perplTrading.isReady || (perplTrading.isEnrolled && wantsTriggers)) ? model.account?.accountId : nil reviewLive = perplTrading.liveOutcomes"))
        XCTAssertTrue(ticket.contains("live: reviewLive, closes: reviewCloses,"))
    }

    func testAnOrdersRowCarriesVolumeOnlyFromWhatFilled() throws {
        let tracker = try DocsLinksTests.appSource("Wallet/PerplOrderTracker.swift")
        let record = try function("static func record(_ outcome: PerplOrderOutcome, _ order: PerplTrackedOrder, kindName: String, hash: Data?, id: UUID?, owner: Address?,", in: tracker)
        let assignments = record.components(separatedBy: "usd = ").dropFirst().map { String($0.prefix { $0 != "\n" }) }
        XCTAssertEqual(assignments.count, 3)
        for assignment in assignments {
            XCTAssertTrue(assignment.hasPrefix("outcome.volumeUSD(priceDecimals: order.priceDecimals, lotDecimals: order.lotDecimals)"), assignment)
        }
        XCTAssertTrue(squeeze(record).contains("if growth.attributable, let p = growth.price, p > 0 {"), "a growth on the chain only when only this order explains it")
        XCTAssertFalse(record.contains("mark"), "never the mark")
        XCTAssertFalse(record.contains("requestedSize *"), "never the size ordered")
        // Nothing executed: no row of its own — only the rewrite of a row a growth on the chain wrote, with no volume.
        XCTAssertTrue(squeeze(record).contains("case .armed, .triggered: return"))
        let nothing = try XCTUnwrap(record.range(of: "case .notFilled, .failed, .expired, .cancelled:"))
        let branchEnd = try XCTUnwrap(record.range(of: "case .armed, .triggered:", range: nothing.upperBound..<record.endIndex))
        let nothingBranch = String(record[nothing.upperBound..<branchEnd.lowerBound])
        XCTAssertFalse(nothingBranch.contains("usd"), "the rewrite carries no volume")
        XCTAssertTrue(nothingBranch.contains("nothing filled"))
        XCTAssertTrue(squeeze(record).contains("Activity.record(row, owner: owner, notify: false)"))
        // A close from the position's Close sheet changes the words only (p4 spec A.6.3): its helper sets no volume.
        XCTAssertTrue(squeeze(record).contains("if order.isClose { (title, subtitle) = closeWords(outcome, order, positionEnded: positionEnded, fallback: subtitle) }"))
        let closeWords = try function("private static func closeWords(", in: tracker)
        XCTAssertFalse(closeWords.contains("usd"), "a close's words never carry volume")
        // The tracker asks for that rewrite only when a growth's row is replaced.
        let kitTracker = try kitSource("Services/Perpl/PerplTracker.swift")
        XCTAssertTrue(squeeze(kitTracker).contains("case .notFilled, .failed, .expired, .cancelled: // The row a growth on the chain wrote (with its volume) is written again: nothing filled, no volume. if previousObserved, order.recordedFillRaw == 0 { effects.append(.recordActivity(outcome)) }"))
        // API rows: no hash, the order's own id (never the relayer's batch transaction).
        XCTAssertTrue(squeeze(tracker).contains("Self.record(outcome, order, kindName: Self.kindName(order), hash: nil, id: order.id, owner: order.owner, positionEnded: positionEnded)"))
        XCTAssertFalse(tracker.contains("txid"), "never at.txid")
        let trading = try DocsLinksTests.appSource("Wallet/PerplTrading.swift")
        XCTAssertTrue(squeeze(trading).contains("let id = PerplOrderTracker.activityID(accountId: t.accountId, rq: t.entryRq, sentAt: sentAt)"))
        XCTAssertTrue(squeeze(trading).contains("PerplOrderTracker.record(entry, latest, kindName: PerplOrderTracker.kindName(latest), hash: nil, id: latest.id, owner: latest.owner)"),
                      "the reconcile's no-volume row for a result never confirmed")
        // A row written again under the same id replaces it.
        XCTAssertTrue(try DocsLinksTests.appSource("Wallet/ActivityLog.swift").contains("list.removeAll { $0.id == record.id }"))
    }

    func testEverySentEntryIsFollowedUnderBackgroundTime() throws {
        let trading = try DocsLinksTests.appSource("Wallet/PerplTrading.swift")
        let track = squeeze(try function("func track(_ t: PerplOrderTracking, input: OrderInput, takeProfit: Double?, stopLoss: Double?, closes: PositionSide?,", in: trading))
        XCTAssertTrue(track.contains("let done = operation(\"Perpl order outcome\")"), "background time, and a draining socket waits (GL-1)")
        XCTAssertTrue(track.contains("defer { done() }"))
        XCTAssertTrue(track.contains("group.addTask { await self.followEntry(id, t, deadline) }"), "the entry settles on its own (I23)")
        XCTAssertTrue(track.contains("guard let sent, sent.ack.accepted, let rq = sent.rq ?? sent.ack.requestId else { continue }"), "refused or unanswered triggers keep their lines")
        XCTAssertTrue(track.contains("if let expected { expectFill(id, input.market.id, input.side, expected, deadline.wallClock) }"), "the watcher waits from the send (I5)")
        XCTAssertFalse(track.contains("signedIn"), "a closed socket answers \"connection lost\" at once")
        // The entry Perpl never answered reaches the sheet with what it needs to follow it, and is never refunded.
        let bracket = squeeze(try function("func submitBracket(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment, ttlBlocks: Int,", in: trading))
        XCTAssertTrue(bracket.contains("} catch let error as PerplTradeError where !error.outcomeUnknown { mera?.refund(charge) throw error } catch let error as PerplTradeError { // Written and never answered: it may be live (no refund, never resent)."))
        XCTAssertTrue(bracket.contains("throw EntryUnanswered(underlying: error, tracking: PerplOrderTracking(client: client,"))
        XCTAssertTrue(bracket.contains("if let entryAck = ack(\"entry\"), entryAck.accepted { result.tracking = PerplOrderTracking("))
        // Effects: a refund only from the tracker's final no-execution; the reload at once.
        let apply = squeeze(try function("private func apply(_ effects: [PerplTrackerEffect], to order: PerplTrackedOrder) {", in: trading))
        XCTAssertTrue(apply.contains("case .refund: mera?.refund(charges.removeValue(forKey: id))"))
        XCTAssertTrue(apply.contains("case .reload: streamRevision &+= 1"))
        XCTAssertTrue(apply.contains("case .voidUserClose: if order.owner == boundOwner { userCloseVoided(order.marketId) }"))
        // Late reports reach the tracker from any socket that has the order, a draining one's included.
        XCTAssertTrue(squeeze(trading).contains("client.onOrderEvents = { [weak self, weak client] _ in guard let self, let client else { return } self.reevaluate(using: client) }"))
        // The reconcile leaves every order a live task follows alone, and posts no notice.
        let reconcile = squeeze(try function("func reconcileLoadedOrders() async {", in: trading))
        XCTAssertTrue(reconcile.contains("!following.contains(order.id) && !resolving.contains(order.id)"))
        XCTAssertTrue(reconcile.contains("await resolveOnce(id, notify: false)"))
        XCTAssertFalse(reconcile.contains("notify: true"))
        let root = squeeze(try DocsLinksTests.appSource("App/RootView.swift"))
        XCTAssertTrue(root.contains("await env.perplTrading.ensureConnected() // Orders sent before the app left the foreground (or before it was closed) whose result never came: // read from the stream, Perpl's history and the chain, with no notice. await env.perplTrading.reconcileLoadedOrders()"))
        // The switch comes from the owner's row (a kill switch: on unless it says JSON false), or until a check of this
        // launch reads it, from the last values read; a launch argument forces it in DEBUG builds only.
        XCTAssertTrue(squeeze(try DocsLinksTests.appSource("App/AppEnvironment.swift")).contains("perplTrading.liveOutcomes = flags.perpsLiveOutcome perplTrading.apiActions = flags.perpsApiActions PerpsSwitchStore.save(flags)"))
        XCTAssertTrue(squeeze(trading).contains("@ObservationIgnored var liveOutcomes = PerplTrading.debugSwitch(\"perpsLiveOutcome\") ?? PerpsSwitchStore.last?.perpsLiveOutcome ?? RemoteFlags.on.perpsLiveOutcome {"))
        XCTAssertTrue(RemoteFlags.on.perpsLiveOutcome)
        // The Perps screens read the chain again the moment a result is in.
        XCTAssertTrue(squeeze(try DocsLinksTests.appSource("Perps/PerpsView.swift")).contains(".onChange(of: env.perplTrading.streamRevision) { _, _ in Task { await model.reloadSoon(env: env, address: session.address) } }"))
    }

    /// Phase 2 (real-time spec §5.4): a cancel reads as done only once Perpl's live list shows it, on the socket that sent
    /// it, and the cancel sheet's rows stay in place; a TP/SL change sends its cancels in one go, waits once for them to
    /// leave the list, and places a replacing trigger only after that wait (GT-1); the leftover clean-up counts what the
    /// list confirmed; every wait sits under the drain's cap.
    func testCancelsAndTriggerChangesConfirmOnPerplsList() throws {
        let sheets = try DocsLinksTests.appSource("Perps/PerpTriggerSheets.swift")
        XCTAssertFalse(sheets.contains("It leaves the list when Perpl confirms."), "no cancel reads as sent-and-forgotten")
        let start = try XCTUnwrap(sheets.range(of: "struct CancelTriggersSheet: View {"))
        let end = try XCTUnwrap(sheets.range(of: "/// Where a TP/SL sheet is:", range: start.upperBound..<sheets.endIndex))
        let cancelSheet = String(sheets[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(cancelSheet.contains("cancelAndConfirm("))
        XCTAssertFalse(cancelSheet.contains("cancel(orders:"))
        XCTAssertFalse(cancelSheet.contains(".transition("), "no row leaves the list")
        XCTAssertFalse(cancelSheet.contains("Activity.record"), "PerplTrading records what Perpl's list confirmed, after the wait")
        let squeezedSheet = squeeze(cancelSheet)
        XCTAssertTrue(squeezedSheet.contains("ForEach(orders) { order in CancelTriggerRow(order: order, market: market, state: rows[order.id] ?? .ready) }"), "every row stays")
        XCTAssertTrue(squeezedSheet.contains("try await perplTrading.cancelAndConfirm(orders: targets, approval: approval) { acks in busy = false"),
                      "Close works once the acks are in (I30b)")
        XCTAssertTrue(squeezedSheet.contains("for order in orders where rows[order.id] == .cancelling { guard let result = perplTrading.cancelLiveResult(order.id) else { continue }"),
                      "the live flip, from the sending socket's list only (I9)")
        XCTAssertTrue(squeezedSheet.contains(".onChange(of: perplTrading.openOrders) { _, _ in flipConfirmed() }"), "as Perpl's list changes")
        XCTAssertTrue(squeezedSheet.contains("guard settled, !busy, perplTrading.ordersAreLive else { return [] } return perplTrading.openOrders.filter {"),
                      "Try Again only after the wait, for what Perpl still lists (I20)")
        XCTAssertTrue(squeezedSheet.contains("if approval == nil, settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: \"Cancel TP/SL\")) { return }"),
                      "App Lock on every run, Try Again included")
        let outcome = squeeze(try function("struct TriggerSheetOutcomeSection: View {", in: sheets))
        XCTAssertTrue(outcome.contains("Label { Paragraph(verbatim: line.text) } icon: {"), "Korean wraps by word (I28)")
        XCTAssertTrue(outcome.contains(".modifier(ParagraphLabel())"))

        let trading = try DocsLinksTests.appSource("Wallet/PerplTrading.swift")
        let confirm = squeeze(try function("func cancelAndConfirm(orders: [PerplOpenOrder], approval: MeraSession.StepUp? = nil,", in: trading))
        XCTAssertTrue(confirm.contains("try requireCancelApproval(approval) let done = operation(\"Perpl cancel\") defer { done() }"),
                      "MERA-PLAN §3, and one operation across the sends and the wait (GL-1)")
        XCTAssertTrue(confirm.contains("guard let result = client.cancelResult(of: key, cancelRq: rq) else { continue }"), "the sending socket's list")
        XCTAssertTrue(confirm.contains("let deadline = Date().addingTimeInterval(PerplTimeouts.removal)"))
        XCTAssertTrue(confirm.contains("for key in awaiting.keys { results[key] = .notConfirmed }"), "never called done in doubt")
        XCTAssertTrue(squeeze(try function("private func settleCancels(", in: trading)).contains("if result == .cancelled, order.isTrigger { cancelled[order.marketId, default: 0] += 1 }"),
                      "the Activity row counts the confirmed TP/SL cancels only (a resting order's has its own row: cancelResting)")
        let live = squeeze(try function("func cancelLiveResult(", in: trading))
        XCTAssertTrue(live.contains("guard ordersAreLive, let client, let request = cancelRequests[key], request.client === client,"))
        XCTAssertTrue(live.contains("client.lastTerminalStatus(of: key) != nil"))

        // One cancel batch, one wait for the removals and one for the new triggers' answers, outside the per-change loops;
        // a replacing trigger only after the wait (GT-1).
        let change = try function("func changeTriggers(_ changes: [TriggerChange], market: PerpMarket, position: PerplLivePosition,", in: trading)
        for call in ["remaining(of:", "awaitOutcomes(", "client.sendEach(replaced.map"] {
            XCTAssertEqual(change.components(separatedBy: call).count - 1, 1, call)
            let line = try XCTUnwrap(change.components(separatedBy: "\n").first { $0.contains(call) })
            XCTAssertLessThanOrEqual(line.prefix { $0 == " " }.count, 16, "\(call): once, outside the per-change loops")
            XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).hasPrefix("for "), call)
        }
        let wait = try XCTUnwrap(change.range(of: "remaining(of:"))
        XCTAssertEqual(change.components(separatedBy: "\n").first { $0.contains("remaining(of:") }?.prefix { $0 == " " }.count, 8)
        XCTAssertEqual(change.components(separatedBy: "\n").first { $0.contains("awaitOutcomes(") }?.prefix { $0 == " " }.count, 8)
        let before = String(change[..<wait.lowerBound]), after = String(change[wait.upperBound...])
        XCTAssertEqual(before.components(separatedBy: "placeTrigger(").count - 1, 1)
        XCTAssertTrue(squeeze(before).contains("for change in ordered where change.replacing.isEmpty {"), "before the wait: only kinds that replace nothing")
        XCTAssertEqual(after.components(separatedBy: "placeTrigger(").count - 1, 1)
        XCTAssertTrue(squeeze(after).contains("for change in awaitingRemoval { guard !change.replacing.contains(where: { stillListed.contains($0.id) }) else { outcomes[change.kind] = .cancelNotConfirmed; continue }"),
                      "GT-1: placed only once every trigger it replaces left the list")
        XCTAssertTrue(change.contains("let live = liveOutcomes"), "the switch, read at the tap")
        XCTAssertTrue(change.contains("cap: PerplTimeouts.triggerOutcome"))

        // The leftover clean-up's quiet row counts what Perpl's list confirmed; the drain's cap covers every wait.
        XCTAssertTrue(trading.contains("self.recordLeftoversCancelled(accepted.count - stillListed.count, of: ended, owner: owner)"))
        XCTAssertTrue(trading.contains("while Date().timeIntervalSince(start) < PerplTimeouts.drainOperation {"))
        XCTAssertLessThan(PerplTimeouts.removal + PerplTimeouts.triggerOutcome + 2, PerplTimeouts.drainOperation)

        // The trade screen: a suspect stream's rows are "Last seen on Perpl" (I10); a card whose cancel is on its way shows
        // it instead of a second Cancel; the leftover banner says what is being cancelled (I32).
        let trade = squeeze(try DocsLinksTests.appSource("Perps/PerpTradeView.swift"))
        XCTAssertTrue(trade.contains("let live = perplTrading.ordersAreLive && !perplTrading.streamSuspect"))
        XCTAssertTrue(trade.contains("TriggerCard(row: row, mark: mark, cancelling: row.order.map { perplTrading.cancellingKeys.contains($0.id) } ?? false)"))
        XCTAssertTrue(trade.contains("Paragraph(verbatim: PerpTriggerCopy.cancellingLeftovers(count: cancelling.count, asset: market.asset))"))
    }

    /// Phase 3 (real-time spec §6.7): a wallet-signed order, close or margin says what its transaction DID, read from the
    /// receipt — "done" is held until it can, and the confirmed step no longer reads as the result; the row written at
    /// the receipt carries no volume (only a fill read back does), the order is followed until its receipt is read even
    /// across a kill, and the Perps screens read the chain again when the live stream reports something.
    func testOnChainResultsAreReadFromTheReceipt() throws {
        // ConfirmationSheet: a plain success haptic only without a result to read; Done held while it is read.
        let run = try DocsLinksTests.appSource("Wallet/TransactionRun.swift")
        XCTAssertFalse(run.contains(".sensoryFeedback(.success, trigger: run.isDone)"))
        XCTAssertTrue(run.contains(".sensoryFeedback(trigger: run.isDone) { _, done in done && settle == nil ? .success : nil }"))
        XCTAssertTrue(run.contains(".sensoryFeedback(trigger: settled?.text.tone) { _, tone in tone.flatMap(PerpOutcomeTone.feedback) }"))
        let squeezedRun = squeeze(run)
        XCTAssertTrue(squeezedRun.contains("if run.isDone, settle != nil { // The result is read from the receipt: \"done\" says what the transaction did, not only that it ran. ReceiptResultBar(settled: settled?.text, reading: reading, holdingDone: holdingDone) { finish() }"))
        XCTAssertTrue(squeezedRun.contains(".disabled(run.isRunning || holdingDone)"))
        XCTAssertTrue(squeezedRun.contains("TransactionProgress(events: run.events, onView: onView, neutralConfirmation: settle != nil)"))
        XCTAssertTrue(squeezedRun.contains("onCompleted?(hash) guard let settle else { return } reading = true holdingDone = true"), "the row first (GL-3), then the read")
        XCTAssertTrue(squeezedRun.contains("let background = BackgroundTime(\"Perpl result\")"), "the read outlives the sheet")
        XCTAssertEqual(run.components(separatedBy: "onStarted?()").count - 1, 2, "right before each run.start, after App Lock and any approval")
        let outcomeView = try DocsLinksTests.appSource("Perps/PerpOrderOutcomeView.swift")
        XCTAssertTrue(outcomeView.contains("static let doneHold: Duration = .seconds(2)"))
        XCTAssertTrue(squeeze(outcomeView).contains("if settled != nil || !holdingDone { PrimaryButton(title: \"Done\", systemImage: \"checkmark\") { onDone() } }"))
        let components = squeeze(try DocsLinksTests.appSource("Design/Components.swift"))
        XCTAssertTrue(components.contains("var neutralConfirmation = false"))
        XCTAssertTrue(components.contains("if neutralConfirmation { Label { Text(\"Transaction confirmed on Monad\""))

        // The on-chain order sheet: the noted close stays (pinned in AppAlertsWiringTests), the row at the receipt has no
        // volume and no notice, the read follows; no notional is recorded as volume anywhere on the trade screen.
        let trade = try DocsLinksTests.appSource("Perps/PerpTradeView.swift")
        let squeezedTrade = squeeze(trade)
        XCTAssertFalse(trade.contains("usd: notional"), "never the size ordered as volume")
        XCTAssertFalse(trade.contains("position.notional > 0 ? position.notional"), "a close's volume is what it filled")
        XCTAssertTrue(squeezedTrade.contains("perplTrading.trackOnChain(id: id, hash: hash, input: reviewedInput, closes: reviewCloses,"))
        XCTAssertTrue(squeezedTrade.contains("}, settle: { _ in guard let id = onChainOrder else { return nil } return await perplTrading.settleOnChainOrder(id) }) {"))
        XCTAssertTrue(squeezedTrade.contains("onChainOrder = perplTrading.expectOnChainOrder(reviewedInput, held: reviewHeld.map { ($0.side, $0.size) })"), "the watcher waits (I5)")
        XCTAssertTrue(squeezedTrade.contains("if PerplTracker.clearsTicket(onChainOrder.flatMap { perplTrading.orders.order($0)?.entry }) { ticket.sizeText = \"\"; sizePercent = 0 }"),
                      "nothing executed: the ticket keeps the order (I26)")
        XCTAssertTrue(squeezedTrade.contains("planDescId = PerplReceipt.descId(ofPlan: plan)"), "the id the plan signs")
        let tracker = try DocsLinksTests.appSource("Wallet/PerplOrderTracker.swift")
        let sent = squeeze(try function("static func recordOnChainSent(_ order: PerplTrackedOrder, hash: Data) {", in: tracker))
        XCTAssertTrue(sent.contains("subtitle: PerpOnChainCopy.orderSent, hash: hash, time: order.sentAt, section: \"perps\", usd: nil), owner: order.owner, notify: false)"))
        let notFilled = squeeze(try function("static func recordOnChainNotFilled(_ order: PerplTrackedOrder, hash: Data) {", in: tracker))
        XCTAssertTrue(notFilled.contains("subtitle: PerpOnChainCopy.nothingFilled, hash: hash, time: order.sentAt, section: \"perps\", usd: nil)"))
        XCTAssertTrue(squeeze(tracker).contains("if case .onChain(let hash) = order.source { // A wallet-signed order's row is its transaction's: the same hash replaces the row written at the receipt. Self.record(outcome, order, kindName: Self.kindName(order), hash: hash, id: nil, owner: order.owner)"))
        XCTAssertTrue(squeeze(tracker).contains("if order.isOnChain { return order.entry.map(PerplTracker.isUnconfirmed) ?? true }"), "stored until its receipt is read")

        // Close: a provisional row with no volume, then what it filled at its price; nothing filled voids the noted close.
        let close = squeeze(try function("private func readResult(_ hash: Data) {", in: String(trade[try XCTUnwrap(trade.range(of: "struct ClosePositionSheet: View {")).lowerBound...])))
        XCTAssertTrue(close.contains("let outcome = accountId.flatMap { PerplReceipt.orderOutcome(requests, accountId: $0, descId: descId.map { BigUInt($0) }) }"))
        XCTAssertTrue(close.contains("usd: outcome?.volumeUSD(priceDecimals: context.priceDecimals, lotDecimals: context.lotDecimals),"))
        XCTAssertEqual(close.components(separatedBy: "usd:").count - 1, 4, "the fill's volume; nil for resting, nothing filled and unread")
        XCTAssertEqual(close.components(separatedBy: "usd: nil").count - 1, 3)
        XCTAssertTrue(close.contains("case let decided? where decided.executedNothing: // Nothing closed: the position's ending is news again, and the row says the transaction filled nothing. onNotSent()"))
        XCTAssertTrue(close.contains("onSettled()"))
        XCTAssertTrue(squeezedTrade.contains("Activity.record(ActivityRecord(kind: .perp, title: PerpOnChainCopy.closeTitle(position.symbol), subtitle: PerpOnChainCopy.closeSent, hash: hash, section: \"perps\", usd: nil), owner: session.address, notify: false) readResult(hash)"))
        // Add margin: the row as today (a confirmed revertOnFail transaction proves it), the read only words the line.
        XCTAssertTrue(squeezedTrade.contains("subtitle: \"\\(NumberStyle.number(amount)) AUSD\", hash: hash, section: \"perps\", usd: amount), owner: session.address) readResult(hash)"))
        XCTAssertTrue(squeezedTrade.contains("PerplReceipt.marginAdded(requests, accountId: accountId, descId: descId.map { BigUInt($0) })"))
        XCTAssertEqual(trade.components(separatedBy: ".sensoryFeedback(.success, trigger: run.isDone)").count - 1, 0, "close and margin feel the result's tone")

        // PerplTrading: the read, its follow-up, and the stream's reloads (the live socket's own reports only).
        let trading = try DocsLinksTests.appSource("Wallet/PerplTrading.swift")
        let decode = squeeze(try function("private func decodeOnChain(_ id: UUID, notify: Bool) async -> PerplOrderOutcome? {", in: trading))
        XCTAssertTrue(decode.contains("let requests = try? await receiptRequests?(hash)"))
        XCTAssertTrue(decode.contains("if orders.order(id)?.entry == nil { settle(id, .unconfirmed(.timedOut), notify: false) }"), "unread: said so, never guessed")
        XCTAssertTrue(decode.contains("if outcome.executedNothing, let latest = orders.order(id) { PerplOrderTracker.recordOnChainNotFilled(latest, hash: hash) }"))
        let redecode = squeeze(try function("func redecodeOnChainOrders() async {", in: trading))
        XCTAssertTrue(redecode.contains("now.timeIntervalSince(last) < Self.redecodeSpacing"))
        XCTAssertTrue(redecode.contains("await decodeOnChain(order.id, notify: false)"), "no notice on a return")
        XCTAssertTrue(squeeze(trading).contains("for order in orders.orders where order.owner == owner && !order.isOnChain && !following.contains(order.id)"),
                      "the reconcile never writes an API row for a wallet-signed order")
        XCTAssertTrue(squeeze(trading).contains("if let client, self.client === client { self.streamActivity() }"), "the live socket's reports")
        let stream = squeeze(try function("private func streamActivity() {", in: trading))
        XCTAssertTrue(stream.contains("self.streamRevision &+= 1"))
        XCTAssertFalse(stream.contains("connect"), "never a reconnect")
        XCTAssertTrue(trading.contains("static let streamDebounce: TimeInterval = 0.25"))
        XCTAssertTrue(trading.contains("static let streamSpacing: TimeInterval = 1"), "at most one reload a second")
        let root = squeeze(try DocsLinksTests.appSource("App/RootView.swift"))
        XCTAssertTrue(root.contains("Task { await env.perplTrading.redecodeOnChainOrders() }"))
        XCTAssertTrue(squeeze(try DocsLinksTests.appSource("App/AppEnvironment.swift")).contains("perplTrading.receiptRequests = { [perpl] hash in try await perpl.receiptRequests(hash) }"))
        // The screens read the chain on the stream's word; the portfolio's history on its fills, at most every 5 s.
        let perps = squeeze(try DocsLinksTests.appSource("Perps/PerpsView.swift"))
        XCTAssertTrue(perps.contains("if let fresh = try? await p, generation > appliedPositionsGeneration {"), "an older read never overwrites a newer one")
        let portfolio = squeeze(try DocsLinksTests.appSource("Perps/PerpsPortfolioView.swift"))
        XCTAssertTrue(portfolio.contains(".onChange(of: perplTrading.historyRevision) { _, _ in reloadHistorySoon() }"))
        XCTAssertTrue(portfolio.contains("private static let historySpacing: TimeInterval = 5"))

        // Recent Activity: a Perpl transaction that confirmed and filled nothing says so.
        let activity = squeeze(try DocsLinksTests.appSource("Wallet/ActivityLog.swift"))
        XCTAssertTrue(activity.contains("case notFilledStatus: return \"minus.circle\""))
        XCTAssertTrue(activity.contains("if let requests = try? await PerplReceipt.requests(ofTransaction: hash, rpc: rpc, attempts: 1), PerplReceipt.allOrdersNotFilled(requests) { return notFilledStatus }"))
    }

    /// A take-profit or stop-loss that isn't known to be live (refused, never answered, never sent) is said from the moment
    /// the order is followed — in the sheet and on the trade screen's status row, whatever the entry is doing, never only
    /// once the entry filled or rests — and an entry Perpl never answered says not to place it again, there too.
    func testATriggerWarningShowsFromTheStartEverywhere() throws {
        let trade = try DocsLinksTests.appSource("Perps/PerpTradeView.swift")
        let lines = try function("private func outcomeLines(_ order: PerplTrackedOrder) -> [PerpOrderOutcomeLine] {", in: trade)
        XCTAssertTrue(squeeze(lines).contains("if let warning = PerpOrderCopy.triggerWarning(order) { lines.append(PerpOrderOutcomeLine(text: warning, tone: .warning)) }"))
        XCTAssertFalse(lines.contains("entry != nil"), "never gated on the entry's result")
        XCTAssertFalse(lines.contains("liveTriggerWarning"))
        // Cancelled "with it" only on evidence; "at once" only from its own wait.
        XCTAssertTrue(squeeze(lines).contains("else if child.checkedNotListed { cancelledWith.append(kind) }"))
        XCTAssertTrue(squeeze(lines).contains("else { mayBeArmed.append(kind) }"))
        XCTAssertFalse(squeeze(lines).contains("else { cancelledWith.append(kind) }"), "never assumed")
        XCTAssertTrue(squeeze(lines).contains("child.settledDuringFollow ? PerpOrderCopy.triggeredAtOnce(kind, price: price) : PerpOrderCopy.triggeredLater(kind)"))
        XCTAssertFalse(trade.contains("unknownMessage"), "one copy of the GL-1 words (PerpOrderCopy.unknown)")
        XCTAssertTrue(squeeze(trade).contains("detail: PerpOrderCopy.unknown(takeProfit: order.takeProfit != nil, stopLoss: order.stopLoss != nil)"))
        // The sheet scrolls to the warning when it starts following, and announces every new headline (not only the first).
        XCTAssertTrue(squeeze(trade).contains(".onChange(of: isTracking) { _, tracking in guard tracking, let order = tracked, let warning = PerpOrderCopy.triggerWarning(order) else { return }"))
        XCTAssertTrue(squeeze(trade).contains(".onChange(of: settledHeadline) { _, headline in guard let headline, headline != announcedHeadline else { return }"))
        XCTAssertTrue(squeeze(trade).contains("if first { withAnimation { proxy.scrollTo(\"outcome\", anchor: .top) } }"))
        XCTAssertFalse(trade.contains("@State private var announced = false"))

        let outcome = try DocsLinksTests.appSource("Perps/PerpOrderOutcomeView.swift")
        let warning = try function("static func triggerWarning(_ order: PerplTrackedOrder) -> String? {", in: outcome)
        XCTAssertFalse(warning.contains("entry != nil") || warning.contains("guard let entry") || warning.contains("guard entry"), "from the children, not the entry")
        XCTAssertTrue(squeeze(warning).contains("} else if let text = refusedUndecided(takeProfit: refusedTP, stopLoss: refusedSL) {"), "refused while undecided")
        let row = String(outcome[try XCTUnwrap(outcome.range(of: "struct PerpOrderStatusRow: View {")).lowerBound...])
        XCTAssertTrue(squeeze(row).contains("if let warning = PerpOrderCopy.triggerWarning(order) {"), "the status row says it too")
        XCTAssertTrue(squeeze(row).contains("if !order.acknowledged { return PerpOrderCopy.unknown(takeProfit: order.takeProfit != nil, stopLoss: order.stopLoss != nil) }"),
                      "GL-1 on the status row")
        // The success that carries it stays on the status row (PerplTrackerTests pins the rule).
        XCTAssertTrue(squeeze(try kitSource("Services/Perpl/PerplTracker.swift")).contains("if entry.tone == .success, !order.hasTriggerWarning {"))
    }

    /// An order removes only its own TP/SL echoes (by id), and only once its own result or a live list read after an entry
    /// that executed nothing says they are gone; that read runs again whenever an entry is decided after its follow, and
    /// after each reconnect.
    func testAnOrderRemovesOnlyItsOwnEchoesOnEvidence() throws {
        let tracker = try DocsLinksTests.appSource("Wallet/PerplOrderTracker.swift")
        XCTAssertTrue(tracker.contains("TriggerStore.remove(ids: [echo], owner: order.owner)"))
        XCTAssertFalse(tracker.contains("TriggerStore.remove(perpId:"), "never every echo of that kind on that side")
        let trade = squeeze(try DocsLinksTests.appSource("Perps/PerpTradeView.swift"))
        XCTAssertTrue(trade.contains("let echoes = recordTriggerEchoes(result)"))
        XCTAssertTrue(trade.contains("echoes: echoes, expectation: expectation)"))
        let trading = try DocsLinksTests.appSource("Wallet/PerplTrading.swift")
        let track = squeeze(try function("func track(_ t: PerplOrderTracking, input: OrderInput, takeProfit: Double?, stopLoss: Double?, closes: PositionSide?,", in: trading))
        XCTAssertTrue(track.contains("notSent: !triggersSent, echoId: triggersSent ? echoes[kind] : nil)"))
        let check = squeeze(try function("private func checkLeftTriggers(_ id: UUID, sentOn sender: PerplTradeClient?) async {", in: trading))
        XCTAssertTrue(check.contains("guard let live, live.signedIn, live.hasOrdersSnapshot, !live.streamSuspect, var current = orders.order(id) else { return }"))
        XCTAssertTrue(check.contains("guard !unnamed else { continue } effects += PerplTracker.markCheckedNotListed(&current, kind: kind, now: now)"))
        let settle = squeeze(try function("private func settle(_ id: UUID, _ outcome: PerplOrderOutcome, notify: Bool = true) {", in: trading))
        XCTAssertTrue(settle.contains("if outcome.executedNothing, !following.contains(id) { Task { await self.checkLeftTriggers(id, sentOn: nil) } }"))
        XCTAssertTrue(squeeze(trading).contains("Task { await self.reconcileLoadedOrders() } self.recheckLeftTriggers()"))
        XCTAssertTrue(squeeze(trading).contains("settleChild(id, kind: kind, outcome, duringFollow: true)"))
        // The leftover sheet's Cancel covers triggers no check could rule out yet, while Perpl lists them.
        XCTAssertTrue(squeeze(trading).contains("let unverified = executedNothing && child.outcome == .armed && !child.checkedNotListed"))
    }

    /// The reads that settle an order whose stream result didn't come: the history never overwrites what the stream
    /// decided meanwhile, and the chain is read as the order's only while its result could still be arriving, never after
    /// a relaunch.
    func testTheFallbackReadsNeverOverwriteOrMisattribute() throws {
        let trading = try DocsLinksTests.appSource("Wallet/PerplTrading.swift")
        let resolve = squeeze(try function("private func resolveOnce(_ id: UUID, notify: Bool) async {", in: trading))
        let history = try XCTUnwrap(resolve.range(of: "if let events = try? await orderHistory(key) {"))
        let ledger = try XCTUnwrap(resolve.range(of: "var ledger = PerplOrderLedger(account: accountId)"))
        XCTAssertTrue(resolve[history.upperBound..<ledger.lowerBound].contains("guard let latest = orders.order(id), Self.needsResolving(latest) else { return }"),
                      "re-checked after the await")
        XCTAssertTrue(resolve.contains("PerplTracker.mayReadChainGrowth(latest, now: Date(), loadedFromDisk: orders.loadedFromDisk.contains(id), window: Self.resolveWindow),"))
        // The settle's finality guard is the tracker's (PerplTrackerTests).
        XCTAssertTrue(squeeze(try kitSource("Services/Perpl/PerplTracker.swift")).contains("if let previous, !previous.canStillChange { return [] }"))
    }

    /// The watcher waits for an order from before its frames are written (the sheet registers it, `track` takes it
    /// over), and a wallet-signed order's window and the watcher's notices count from before it was signed.
    func testTheWatchersWaitStartsBeforeTheSend() throws {
        let trade = try DocsLinksTests.appSource("Perps/PerpTradeView.swift")
        let live = squeeze(try function("private func place(approval: MeraSession.StepUp? = nil) async {", in: trade))
        let expect = try XCTUnwrap(live.range(of: "let expectation = perplTrading.expectOrder(input, held: held)"))
        let send = try XCTUnwrap(live.range(of: "submitBracket("))
        XCTAssertLessThan(expect.lowerBound, send.lowerBound, "before the first frame")
        XCTAssertTrue(live.contains("defer { if !followed { perplTrading.releaseOrderExpectation(expectation) } }"))
        XCTAssertEqual(live.components(separatedBy: "followed = true").count - 1, 2, "both tracked paths take it over")
        let trading = try DocsLinksTests.appSource("Wallet/PerplTrading.swift")
        let track = squeeze(try function("func track(_ t: PerplOrderTracking, input: OrderInput, takeProfit: Double?, stopLoss: Double?, closes: PositionSide?,", in: trading))
        let release = try XCTUnwrap(track.range(of: "if let expectation { releaseFill(expectation.id) }"))
        let rekey = try XCTUnwrap(track.range(of: "if let expected { expectFill(id, input.market.id, input.side, expected, deadline.wallClock) }"))
        XCTAssertLessThan(release.lowerBound, rekey.lowerBound)
        XCTAssertTrue(track.contains("order.expectedSince = expectation?.since"))
        let onChain = squeeze(try function("func trackOnChain(id: UUID, hash: Data, input: OrderInput, closes: PositionSide?, held: (side: PositionSide, size: Double)?,", in: trading))
        XCTAssertTrue(onChain.contains("deadline: PerplOutcomeDeadline(ackHead: nil, ttlBlocks: nil, ackAt: expectedSince ?? sentAt, cap: Self.onChainExpectation),"))
        XCTAssertTrue(onChain.contains("order.expectedSince = expectedSince"))
        XCTAssertTrue(squeeze(trading).contains("watcherAnnouncedSinceSent: watcherAnnounced(order.marketId, order.side, order.noticeSince))"))
    }

    /// The automatic leftover clean-up never leaves a "Cancelling…" behind for a cancel that never went out or that Perpl
    /// refused: those may be offered (and swept) again.
    func testTheLeftoverCleanUpLetsGoOfCancelsThatDidntGoOut() throws {
        let trading = squeeze(try DocsLinksTests.appSource("Wallet/PerplTrading.swift"))
        XCTAssertTrue(trading.contains("let noted = self.notePendingCancels(leftovers.map(\\.id), on: client)"))
        XCTAssertTrue(trading.contains("for order in leftovers where self.cancelsPending[order.id]?.at == noted { self.cancelsPending[order.id] = nil self.cancelsSent.remove(order.id) } return }"))
        XCTAssertTrue(trading.contains("for (order, ack) in zip(leftovers, acks) where !ack.accepted && !ack.outcomeUnknown && self.cancelsPending[order.id]?.at == noted { self.cancelsPending[order.id] = nil self.cancelsSent.remove(order.id) }"))
    }

    /// The switch-off sheet's notional volume is a documented exception awaiting the owner's decision, not an oversight.
    func testTheSwitchOffVolumeIsADocumentedException() throws {
        let trade = try DocsLinksTests.appSource("Perps/PerpTradeView.swift")
        let legacy = try function("private func placeLegacy(approval: MeraSession.StepUp? = nil) async {", in: trade)
        XCTAssertTrue(legacy.contains("KNOWN EXCEPTION to \"volume only from what filled\" (owner decision pending"))
    }
}
