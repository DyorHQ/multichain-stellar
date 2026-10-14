import XCTest
@testable import DyorKit

/// Close, Cancel Order and Add Margin over Perpl's trading connection (p4 spec A), read from the app's sources: the path
/// decided at the tap and never switched; the on-chain path kept as the fallback; MERA-PLAN §3's step-ups and App Lock
/// before anything is sent; nothing resent; a refused route resting on its socket only for transport or permission
/// refusals; every result from Perpl's evidence, in the sheet, a notice and Activity — and no volume but what moved.
final class PerpsApiActionsWiringTests: XCTestCase {
    private func squeeze(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The text of the function that starts at `signature`, up to its closing brace at the indentation it opened at.
    private func function(_ signature: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), signature)
        let line = text[..<start.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let indent = String(line.prefix { $0 == " " })
        let end = try XCTUnwrap(text.range(of: "\n" + indent + "}\n", range: start.upperBound..<text.endIndex), signature)
        return String(text[start.lowerBound..<end.upperBound])
    }

    /// The text from `start` up to (not including) `end`.
    private func section(_ text: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    private func assertOrder(_ text: String, _ parts: [String], file: StaticString = #filePath, line: UInt = #line) {
        var cursor = text.startIndex
        for part in parts {
            guard let found = text.range(of: part, range: cursor..<text.endIndex) else {
                return XCTFail("\(part) missing or out of order", file: file, line: line)
            }
            cursor = found.upperBound
        }
    }

    private var trading: String { get throws { try DocsLinksTests.appSource("Wallet/PerplTrading.swift") } }
    private var trade: String { get throws { try DocsLinksTests.appSource("Perps/PerpTradeView.swift") } }

    /// A.2: the route needs both switches, this socket's own forwarding report (never the on-chain grant) for the account
    /// at the tap, and no refusal on this socket; a locked passkey account only for Close / Add Margin, only when its last
    /// socket reported forwarding on. The trade screen decides it at the tap that opens each sheet, and a gone order opens
    /// no sheet.
    func testThePathIsDecidedAtTheTap() throws {
        let trading = try trading
        let live = squeeze(try function("func apiActionsLive(for account: ActionAccount) -> Bool {", in: trading))
        XCTAssertTrue(live.contains("liveOutcomes && apiActions && isReady && client?.forwardingEnabled == true"))
        XCTAssertTrue(live.contains("client?.accountId == account.accountId && boundOwner == account.owner && boundToPasskey == account.passkey"))
        XCTAssertTrue(live.contains("!(apiBlocked?.client === client && client != nil)"))
        XCTAssertFalse(live.contains("isForwarding") || live.contains("forwardingGrantedOnChain"), "the socket's own report, never the on-chain grant")
        let unlock = squeeze(try function("func apiActionsAfterUnlock(for account: ActionAccount) -> Bool {", in: trading))
        XCTAssertTrue(unlock.contains("liveOutcomes && apiActions && boundToPasskey && account.passkey && boundOwner == account.owner"))
        XCTAssertTrue(unlock.contains("storedToken != nil && !keyRejected && !isReady"))
        XCTAssertTrue(unlock.contains("PerplForwardingMemory.lastKnown(chainId: Monad.chainId, accountId: account.accountId) == true"))
        // Only while the socket can come back for it: no failed connect (the 1008 cap, a rejected key), no back-off pending, and
        // no refusal of the route since the last sign-in — one recorded with no socket (a connect that failed after the
        // step-up) included. Otherwise the step-up's Face ID would be spent on a request that can't go out.
        XCTAssertTrue(unlock.contains("&& failureMessage == nil && Date() >= retryAfter && !apiRefusedSinceSignIn"))
        XCTAssertTrue(squeeze(trading).contains("private var apiRefusedSinceSignIn: Bool { apiBlocked.map { $0.at >= lastSignedInAt } ?? false }"))
        let signIn = squeeze(try function("private func performConnect() async throws {", in: trading))
        assertOrder(signIn, ["try await client.connect()", "guard self.client === client else { throw PerplTradeError.notSignedIn }", "resetRetry()",
                             "lastSignedInAt = Date()", "syncStatus()"])
        XCTAssertEqual(trading.components(separatedBy: "lastSignedInAt = Date()").count - 1, 1, "only a sign-in clears a refusal")
        XCTAssertTrue(squeeze(try function("func noteAPIRefusal(on client: PerplTradeClient?) {", in: trading)).contains("apiBlocked = APIBlock(client: client, at: Date())"))
        // The memory is the socket's own report, written while it is signed in.
        XCTAssertTrue(squeeze(try function("private func syncStatus() {", in: trading)).contains("PerplForwardingMemory.record(client.forwardingEnabled, chainId: Monad.chainId, accountId: id)"))
        XCTAssertEqual(trading.components(separatedBy: "PerplForwardingMemory.record(").count - 1, 1)
        XCTAssertTrue(trading.contains("@ObservationIgnored var apiActions = PerplTrading.debugSwitch(\"perpsApiActions\") ?? PerpsSwitchStore.last?.perpsApiActions ?? RemoteFlags.on.perpsApiActions"))
        XCTAssertTrue(trading.contains("@ObservationIgnored var liveOutcomes = PerplTrading.debugSwitch(\"perpsLiveOutcome\") ?? PerpsSwitchStore.last?.perpsLiveOutcome ?? RemoteFlags.on.perpsLiveOutcome"))

        let trade = try trade
        let squeezedTrade = squeeze(trade)
        XCTAssertEqual(trade.components(separatedBy: "apiRoute").count - 1, 3, "its definition and the two PositionCard taps")
        XCTAssertTrue(squeezedTrade.contains("onClose: { closeRoute = apiRoute; closingPosition = position }, onAddMargin: { marginRoute = apiRoute; addingMargin = position },"))
        XCTAssertTrue(squeezedTrade.contains("return perplTrading.apiActionsLive(for: account) || perplTrading.apiActionsAfterUnlock(for: account) ? account : nil"))
        XCTAssertTrue(squeezedTrade.contains("guard session.canSign, let id = model.account?.accountId else { return nil }"), "watch-only: the wallet's sheets")
        let tap = squeeze(try function("private func tapCancel(_ order: PerpOrder) {", in: trade))
        // A cancel from this device that Perpl's list confirmed: no sheet. The stream's word alone that the order left never
        // refuses the wallet's cancel: the chain is read again, and an order it still lists opens the wallet's sheet (A.4.2).
        assertOrder(tap, ["if let gone = perplTrading.chainOrderGone(order) {", "if gone.byCancel { Haptics.warning() }",
                          "await model.load(env: env, address: session.address)", "guard !gone.byCancel else { return }",
                          "guard let fresh = model.orders.first(where: { PerplTrading.ChainOrderKey($0) == PerplTrading.ChainOrderKey(order) }) else {",
                          "cancelTarget = nil", "cancelAccount = nil", "cancellingOrder = fresh", "return }",
                          "if let account = actionAccount, perplTrading.apiActionsLive(for: account), perplTrading.ordersAreLive, !perplTrading.streamSuspect {",
                          "cancelTarget = PerplOpenOrder.streamOrder(for: order, in: perplTrading.openOrders, priceDecimals: market.priceDecimals)",
                          "cancelTarget = nil", "cancellingOrder = order"])
        XCTAssertFalse(tap.contains("apiActionsAfterUnlock"), "never a cancel without a live list")
        assertOrder(squeezedTrade, [".sheet(item: $cancellingOrder) { order in", "if let target = cancelTarget, let account = cancelAccount { CancelOrderSheet(market: market, order: order, target: target, tapRq: cancelTapRq, account: account)",
                                    "} else { cancelOrderSheet(order) }"])
        // The sheets keep their path as `let`s.
        XCTAssertTrue(squeezedTrade.contains("var route: PerplTrading.ActionAccount? = nil"))
        XCTAssertTrue(squeezedTrade.contains("route: closeRoute,"))
        XCTAssertTrue(squeezedTrade.contains("route: marginRoute,"))
    }

    /// The route rests on a socket only after a transport or permission refusal (#2): never after a market result.
    func testARefusedRouteRestsOnlyOnTransportOrPermission() throws {
        let trading = try trading
        for line in trading.components(separatedBy: "\n") where line.contains("noteAPIRefusal(") {
            XCTAssertFalse(line.contains("16") || line.contains("executedNothing"), line)
        }
        let close = squeeze(try function("func submitClose(_ request: CloseRequest, account: ActionAccount, env: AppEnvironment, approval: MeraSession.StepUp?,", in: trading))
        XCTAssertTrue(close.contains("if !result.entry { noteAPIRefusal(on: writer ?? client) }"), "a refused entry ack")
        XCTAssertTrue(close.contains("} catch let error as PerplTradeError where !error.outcomeUnknown { if !error.isInvalidOrder { noteAPIRefusal(on: writer ?? client) } throw error }"))
        let margin = squeeze(try function("func addMargin(market: PerpMarket, amount: Double, account: ActionAccount, before: PerpPosition?, approval: MeraSession.StepUp?,", in: trading))
        XCTAssertTrue(margin.contains("if !ack.accepted, !ack.outcomeUnknown { movedNothing = true noteAPIRefusal(on: client)"), "a gateway refusal")
        let cancel = squeeze(try function("func cancelResting(_ target: PerplOpenOrder, tapRq: Int?, chainOrder: ChainOrderKey, account: ActionAccount, title: String,", in: trading))
        // The gateway's refusal rests the route BEFORE the sheet words its line (`onAcks`), so the line names the wallet.
        assertOrder(cancel, ["if let decided = acks[target.id], decided != .notConfirmed {", "refusedAtGateway = true",
                             "self.noteAPIRefusal(on: sender ?? self.client)", "onAcks(acks)"])
        XCTAssertTrue(cancel.contains("if !refusedAtGateway, cancelRefusedForForwarding(target.id) { noteAPIRefusal("))
        XCTAssertTrue(squeeze(trading).contains("if reason.reason == 34 { noteAPIRefusal(on: client) }"), "OrderForwardingNotAllowed")
        // A close Perpl refused with sr 34 rests the route on the socket that sent it, as Add Margin and Cancel Order do.
        let settle = squeeze(try function("private func settle(_ id: UUID, _ outcome: PerplOrderOutcome, notify: Bool = true) {", in: trading))
        assertOrder(settle, ["apply(effects, to: order)",
                             "if order.purpose != nil, case .failed(let reason) = outcome, reason.reason == 34 { noteAPIRefusal(on: closeClients[id]?.client) }"])
        // The line under a not-sent failure names the wallet only when the reopened sheet will go on-chain for sure — with no
        // live socket, when none will be tried for it (`apiActionsAfterUnlock`'s own conditions).
        let line = squeeze(try function("func nothingSentLine(for account: ActionAccount) -> String {", in: trading))
        XCTAssertTrue(line.contains("let blocked = live && apiBlocked?.client === client"))
        XCTAssertTrue(line.contains("let down = !live && (failureMessage != nil || Date() < retryAfter || apiRefusedSinceSignIn)"))
        XCTAssertTrue(line.contains("let onChain = !liveOutcomes || !apiActions || !isEnrolled || blocked || forwardingOff || rememberedOff || down"))
        // A not-sent failure after the step-up (the socket didn't come back) is recorded with whatever socket there is — none
        // included — so the next tap's route is the wallet's (`apiActionsAfterUnlock` reads `apiRefusedSinceSignIn`).
        XCTAssertTrue(close.contains("if !error.isInvalidOrder { noteAPIRefusal(on: writer ?? client) }"))
        XCTAssertTrue(margin.contains("} catch let error as PerplTradeError { if !error.isInvalidOrder { noteAPIRefusal(on: self.client) } throw error }"))

        // The sheets: after a refusal for forwarding, the wallet's line and no Try Again on this route.
        let trade = try trade
        let closeSheet = try section(trade, from: "struct ClosePositionSheet: View {", to: "struct AddMarginSheet: View {")
        XCTAssertTrue(squeeze(closeSheet).contains("if case .failed(let reason)? = tracked?.entry { return reason.reason == 34 }"))
        let bar = squeeze(try function("@ViewBuilder private func apiBar(_ route: PerplTrading.ActionAccount) -> some View {", in: closeSheet))
        assertOrder(bar, ["if refusedForForwarding {", "Paragraph(verbatim: perplTrading.nothingSentLine(for: route))", "} else if entry.executedNothing {",
                          "PrimaryButton(title: \"Try Again\""])
        XCTAssertTrue(squeeze(try function("private func tryAgain(_ route: PerplTrading.ActionAccount) {", in: closeSheet))
                        .contains("guard case .tracking(let old) = apiPhase, executedNothing, !refusedForForwarding else { return }"))
        let cancelSheet = squeeze(try section(try DocsLinksTests.appSource("Perps/PerpTriggerSheets.swift"), from: "struct CancelOrderSheet: View {", to: "private struct CancelTriggerRow: View {"))
        XCTAssertTrue(cancelSheet.contains("if case .refused = outcome, perplTrading.cancelRefusedForForwarding(target.id) { failureLine = perplTrading.nothingSentLine(for: account) }"),
                      "a failure line hides Try Again (`canRetry`)")
    }

    /// #3: each sheet's API confirm is busy at once, behind a guard that takes only a sheet with nothing under way — a
    /// double tap, or a tap during the App Lock prompt, never starts a second request.
    func testEveryAPIConfirmIsGuardedBeforeItsTask() throws {
        let trade = try trade
        let sheets = try DocsLinksTests.appSource("Perps/PerpTriggerSheets.swift")
        let confirms = [
            try function("private func confirmAPI(_ route: PerplTrading.ActionAccount) {", in: try section(trade, from: "struct ClosePositionSheet: View {", to: "struct AddMarginSheet: View {")),
            try function("private func confirmAPI(_ route: PerplTrading.ActionAccount) {", in: try section(trade, from: "struct AddMarginSheet: View {", to: "struct AuthedOrderSheet: View {")),
            try function("private func confirm() {", in: try section(sheets, from: "struct CancelOrderSheet: View {", to: "private struct CancelTriggerRow: View {")),
        ]
        for confirm in confirms.map(squeeze) {
            XCTAssertTrue(confirm.contains("guard apiPhase == .review || apiPhase.isFailed"), confirm)
            assertOrder(confirm, ["guard apiPhase == .review || apiPhase.isFailed", "else { return }", "apiPhase = .authorizing", "Task {"])
        }
    }

    /// The Close sheet on the trading connection (A.3.1, A.4.1): App Lock, the passkey session held, then `submitClose`
    /// (its step-up inside, before any frame); the close noted only as it is written; every not-sent exit un-notes it;
    /// what was written is always followed, with no socket condition; Try Again only after Perpl's final "nothing
    /// executed"; no wallet transaction and no Activity row from the sheet.
    func testTheCloseSheetsAPIConfirm() throws {
        let sheet = try section(try trade, from: "struct ClosePositionSheet: View {", to: "struct AddMarginSheet: View {")
        let confirm = squeeze(try function("private func closeOverAPI(_ route: PerplTrading.ActionAccount, approval: MeraSession.StepUp? = nil) async {", in: sheet))
        assertOrder(confirm, ["BiometricGate.authenticate(reason: \"Confirm close\")", "session.mera.beginAction()", "defer { session.mera.endAction() }", "perplTrading.submitClose("])
        XCTAssertEqual(confirm.components(separatedBy: "onSending(").count - 1, 1)
        XCTAssertTrue(confirm.contains("onWriting: { whole in onSending(whole) }"), "noted right before the write")
        let failures = confirm.components(separatedBy: "apiPhase = .failed(")
        XCTAssertEqual(failures.count - 1, 4)
        for before in failures.dropLast() { XCTAssertTrue(before.suffix(260).contains("onNotSent()"), String(before.suffix(260))) }
        XCTAssertTrue(confirm.contains("} catch where isUserCancellation(error) { onNotSent()"))
        XCTAssertTrue(confirm.contains("catch is MeraSession.StepUpRequired where approval == nil"))
        XCTAssertEqual(confirm.components(separatedBy: "perplTrading.track(").count - 1, 2)
        XCTAssertEqual(confirm.components(separatedBy: "purpose: .close(wholePosition: whole))").count - 1, 2)
        let unanswered = try XCTUnwrap(confirm.range(of: "} catch let unanswered as PerplTrading.EntryUnanswered {"))
        XCTAssertTrue(confirm[unanswered.upperBound...].prefix(400).contains("let id = perplTrading.track(unanswered.tracking, input: unanswered.input,"), "I7: always followed")
        XCTAssertFalse(confirm.contains("signedIn"))
        XCTAssertFalse(confirm.contains("run.start") || confirm.contains("Activity.record"))
        // Try Again: only under Perpl's final "nothing executed", never for a result not confirmed.
        let bar = squeeze(try function("@ViewBuilder private func apiBar(_ route: PerplTrading.ActionAccount) -> some View {", in: sheet))
        assertOrder(bar, ["if let entry = order.entry, !PerplTracker.isUnconfirmed(entry) {", "if entry.executedNothing {", "PrimaryButton(title: \"Try Again\"",
                          "} else if let entry = order.entry {", "PrimaryButton(title: \"Close\""])
        XCTAssertEqual(bar.components(separatedBy: "Try Again").count - 1, 1)
        let again = squeeze(try function("private func tryAgain(_ route: PerplTrading.ActionAccount) {", in: sheet))
        assertOrder(again, ["guard case .tracking(let old) = apiPhase, executedNothing, !refusedForForwarding else { return }", "perplTrading.orders.setPresented(old, false)",
                            "perplTrading.orders.dismissBanner(old)", "confirmAPI(route)"])
        // The on-chain path, as before, with the chips.
        XCTAssertTrue(squeeze(sheet).contains("env.perpl.closePositionPlan(market: market, position: position, slippageBps: Self.slippageBps, kind: kind, limitPrice: limitPrice, postOnly: postOnly, size: sentSize)"))
        XCTAssertTrue(squeeze(sheet).contains("ForEach([25, 50, 75, 100], id: \\.self) { chip in"))
        XCTAssertTrue(squeeze(sheet).contains(".disabled(termsLocked || chipSize(chip) == nil)"))
        XCTAssertTrue(squeeze(sheet).contains("title: partly || partOnly ? PerpOnChainCopy.partlyClosedTitle(symbol) : tr(\"Closed \\(symbol)\")"))
        XCTAssertTrue(squeeze(sheet).contains(".interactiveDismissDisabled(run.isRunning || holdingDone || apiPhase == .sending || apiPhase == .authorizing)"))
        XCTAssertTrue(squeeze(sheet).contains(".onDisappear { if case .tracking(let id) = apiPhase { perplTrading.orders.setPresented(id, false) } }"))
    }

    /// The Add Margin sheet on the trading connection (A.3.1, A.4.3): App Lock, the session held, the amount checks the
    /// device can make, then `addMargin`; the sheet writes no row (PerplTrading does); presented while on screen, so a
    /// result decided after it closes is a notice.
    func testTheMarginSheetsAPIConfirm() throws {
        let sheet = try section(try trade, from: "struct AddMarginSheet: View {", to: "struct AuthedOrderSheet: View {")
        let confirm = squeeze(try function("private func addOverAPI(_ route: PerplTrading.ActionAccount, approval: MeraSession.StepUp? = nil) async {", in: sheet))
        assertOrder(confirm, ["BiometricGate.authenticate(reason: \"Confirm add margin\")", "session.mera.beginAction()", "if overBalance {",
                              "PerplOrders.problem(PerplOrders.addMargin(", "perplTrading.addMargin("])
        XCTAssertFalse(confirm.contains("Activity.record"))
        XCTAssertTrue(confirm.contains("perplTrading.setMarginPresented(id, true)"), "presented from the write")
        XCTAssertTrue(squeeze(sheet).contains(".onDisappear { // A result decided from now on posts its notice (and its Activity row, either way). if let marginId { perplTrading.setMarginPresented(marginId, false) } }"))
        XCTAssertTrue(squeeze(sheet).contains(".sensoryFeedback(trigger: apiText?.tone)"))
        // Once the request is written the toolbar never says "Cancel": it can't be called back (as Close Position and Cancel Order).
        XCTAssertTrue(squeeze(sheet).contains("Button(run.isDone || apiResult != nil ? \"Done\" : (marginId != nil || apiPhase == .sending ? \"Close\" : \"Cancel\")) { finish() }"))
        XCTAssertTrue(squeeze(sheet).contains("beforeAt: freshBefore != nil ? freshBeforeAt : nil)"), "the chain's before, with when it was read")
        XCTAssertTrue(squeeze(sheet).contains("AccessibilityNotification.Announcement(headline).post()"))
        // The wallet's margin row, as before.
        XCTAssertTrue(squeeze(sheet).contains("Activity.record(ActivityRecord(kind: .deposit, title: tr(\"Added \\(position.symbol) margin\"), subtitle: \"\\(NumberStyle.number(amount)) AUSD\", hash: hash, section: \"perps\", usd: amount), owner: session.address)"))
    }

    /// `PerplTrading.addMargin` (A.4.3): the device's checks before the step-up, the step-up before the connection, the
    /// account checked on the socket that writes, one request never resent, Perpl's evidence and the chain's, and the rows
    /// and notices filed under the tap's account.
    func testAddMargin() throws {
        let trading = try trading
        let add = squeeze(try function("func addMargin(market: PerpMarket, amount: Double, account: ActionAccount, before: PerpPosition?, approval: MeraSession.StepUp?,", in: trading))
        assertOrder(add, ["PerplOrders.problem(PerplOrders.addMargin(", "Self.overAvailable(amountCNS, on: client)", "try mera.requireStepUp(approval, for: .unlisted)",
                          "let done = operation(\"Perpl margin\")", "try requireAction(account, on: client)", "client.sendEach([PerplOrders.addMargin("])
        XCTAssertEqual(add.components(separatedBy: "sendEach(").count - 1, 1)
        XCTAssertFalse(add.contains(".place(") || add.contains("placeAll("))
        XCTAssertTrue(add.contains("let id = PerplOrderTracker.marginActivityID(accountId: account.accountId, rq: rq, sentAt: writtenAt)"))
        XCTAssertTrue(squeeze(try function("private static func overAvailable(_ amountCNS: BigUInt, on client: PerplTradeClient) -> Bool {", in: trading))
                        .contains("let available = balance > locked ? balance - locked : 0"), "saturating (#12)")
        for (path, text) in [("Wallet/PerplTrading.swift", trading), ("Perps/PerpTradeView.swift", try trade)] {
            XCTAssertFalse(text.contains("balanceCNS - lockedBalanceCNS") || text.contains("balance - locked)"), path)
        }
        let evidence = squeeze(try function("private func marginEvidence(_ pending: PendingMargin, on client: PerplTradeClient) async -> MarginResult {", in: trading))
        XCTAssertTrue(evidence.contains("let deadline = pending.writtenAt.addingTimeInterval(PerplTimeouts.marginEvidence)"))
        XCTAssertTrue(evidence.contains("var polls = [2.0, 5.0, 10.0].map { pending.writtenAt.addingTimeInterval($0) }"))
        XCTAssertTrue(evidence.contains("let read = readPositions"))
        XCTAssertTrue(evidence.contains("client.collateralOutcome(rq: pending.rq, final: client.continuityHeld(since: pending.writtenAt))"))
        XCTAssertTrue(evidence.contains("if self.chainShowsMargin(positions, pending, before: before) { chain.added = true }"))
        // The chain credits a request only when nothing else could have moved the collateral (R.1.6, R.1.7): the position's
        // size unchanged and its collateral grown by the amount to the cent (`PerplMarginEvidenceTests`), no other margin
        // request on that market since its before, no order of this device's there; a position whose size moved is never
        // read for it again.
        let chain = squeeze(try function("private func chainShowsMargin(_ positions: [PerpPosition], _ pending: PendingMargin, before: PerpPosition) -> Bool {", in: trading))
        assertOrder(chain, ["if PerplMarginEvidence.sizeMoved(in: positions, before: before, lotDecimals: lotDecimals) { marginChainExcluded.insert(pending.token) }",
                            "guard !marginChainExcluded.contains(pending.token),",
                            "PerplMarginEvidence.chainShows(positions, before: before, amount: pending.amount, lotDecimals: lotDecimals),",
                            "!PerplMarginEvidence.otherMargin(than: pending.token, on: pending.market.id, since: pending.beforeAt, among: marginRequests),",
                            "!ordersMoved(on: pending.market.id,"])
        XCTAssertFalse(trading.contains(">= before.margin + pending.amount"), "never \"at least\" the amount")
        XCTAssertFalse(trading.contains("marginsInFlight"), "every margin request is on record, in flight or not, whichever list")
        let stream = squeeze(try function("private func streamMarginResult(_ pending: PendingMargin, on client: PerplTradeClient) -> MarginResult? {", in: trading))
        assertOrder(stream, ["let otherMargin = PerplMarginEvidence.otherMargin(than: pending.token, on: pending.market.id, since: pending.writtenAt, among: marginRequests)",
                             "let otherOrder = ordersMoved(on: pending.market.id, since: pending.writtenAt)", "guard !otherMargin, !otherOrder,"])
        XCTAssertTrue(squeeze(try function("private func ordersMoved(on marketId: Int, since: Date) -> Bool {", in: trading))
                        .contains("orders.orders.contains { $0.marketId == marketId && $0.sentAt > since } || following.contains { orders.order($0)?.marketId == marketId }"))
        let read = squeeze(try function("func marginPositionsRead(_ positions: [PerpPosition], at: Date, owner: Address?) {", in: trading))
        XCTAssertTrue(read.contains("for id in pendingMargins.values.sorted(by: { $0.writtenAt < $1.writtenAt }).map(\\.id) {"), "one credit decided before the next")
        XCTAssertTrue(read.contains("let before = entry.before, chainShowsMargin(positions, entry, before: before) else { continue }"))
        // A request is on record from its tap: forgotten at once only if it provably moved nothing; settled once its result
        // can't change (added, or out of the re-check list).
        assertOrder(add, ["marginRequests[token] = PerplMarginEvidence.Request(marketId: market.id, startedAt: Date())",
                          "defer { if movedNothing { marginRequests[token] = nil } }", "client.sendEach([PerplOrders.addMargin(", "movedNothing = false",
                          "if !ack.accepted, !ack.outcomeUnknown { movedNothing = true"])
        XCTAssertTrue(squeeze(trading).contains("for (id, entry) in oldValue where pendingMargins[id] == nil { releaseMarginRequest(entry.token) }"))
        // Volume only on an added row: the wallet's own row, field for field (R.1.1).
        let settle = squeeze(try function("private func settleMargin(_ pending: PendingMargin, first: Bool) {", in: trading))
        XCTAssertTrue(settle.contains("case .added(let cns): pendingMargins[pending.id] = nil releaseMarginRequest(pending.token)"))
        XCTAssertFalse(settle.contains("usd:"))
        XCTAssertFalse(settle.contains("boundOwner") || settle.contains("session"))
        XCTAssertTrue(settle.contains("row.id = pending.id"))
        let added = squeeze(try function("private func recordMarginAdded(_ pending: PendingMargin, cns: BigUInt) {", in: trading))
        XCTAssertTrue(added.contains("ActivityRecord(kind: .deposit, title: tr(\"Added \\(pending.symbol) margin\"), subtitle: \"\\(NumberStyle.number(added)) AUSD\", hash: nil, section: \"perps\", usd: added)"))
        XCTAssertTrue(added.contains("Activity.record(row, owner: pending.account.owner)"))
        XCTAssertEqual(trading.components(separatedBy: "usd: added").count - 1, 1)
        let notice = squeeze(try function("private func postMarginNotice(_ title: String, body: String, _ pending: PendingMargin) {", in: trading))
        assertOrder(notice, ["guard let owner = pending.account.owner, !marginPresented.contains(pending.id) else { return }", "Notifications.perpMargin("])
        // The re-checks: the sending socket's reports, the screens' chain reads, the reconcile.
        XCTAssertTrue(squeeze(try function("private func reevaluate(using client: PerplTradeClient) {", in: trading)).contains("recheckMargins(on: client)"))
        XCTAssertTrue(squeeze(try function("func reconcileLoadedOrders() async {", in: trading)).contains("await recheckMarginsOnChain(owner: owner)"))
        let perps = squeeze(try DocsLinksTests.appSource("Perps/PerpsView.swift"))
        XCTAssertTrue(perps.contains("env.perplTrading.marginPositionsRead(fresh, at: readAt, owner: address)"))
        XCTAssertTrue(perps.contains("orders = freshOrders // Only a successful chain read forgets an order Perpl's list showed gone. env.perplTrading.chainOrdersRead(freshOrders)"))
        // The step-up the wallet's margin asks today.
        XCTAssertTrue(try DocsLinksTests.appSource("Wallet/Mera/MeraWallet.swift").contains("case .unlisted: return Mera.AlwaysAsk.unlisted.summary"))
    }

    /// `submitClose` (A.4.1) and `cancelResting` (A.4.2): the close's last checks and its size on the socket that writes
    /// it, right before the write; the cancel's identity check before anything is sent; one path each.
    func testSubmitCloseAndCancelResting() throws {
        let trading = try trading
        let close = squeeze(try function("func submitClose(_ request: CloseRequest, account: ActionAccount, env: AppEnvironment, approval: MeraSession.StepUp?,", in: trading))
        XCTAssertTrue(close.contains("submitBracket(input: input, accountId: account.accountId, takeProfit: nil, stopLoss: nil, env: env, ttlBlocks: 100,"))
        assertOrder(close, ["beforeWrite: { client in", "try self.requireAction(account, on: client)", "sent = Self.closeInput(request, input: input, on: client)", "onWriting(whole)"])
        XCTAssertTrue(close.contains("if let problem = PerplOrders.problem(PerplOrders.entry(input, accountId: account.accountId, head: 0)) { throw PerplTradeError.invalidOrder(problem) }"),
                      "refused on the device before any step-up")
        let bracket = squeeze(try function("func submitBracket(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment, ttlBlocks: Int,", in: trading))
        assertOrder(bracket, ["if let fixed = try beforeWrite(client) { input = fixed }", "} catch { mera?.refund(charge) throw error }", "let entryRq = client.reserveRequestId()",
                              "acks = try await client.placeAll(frames)"])
        XCTAssertTrue(bracket.contains("input: input)"), "an unanswered close carries what was written")
        XCTAssertFalse(trading.contains("func closePosition("))
        XCTAssertFalse(trading.contains("func cancel(perpId:"))

        let cancel = squeeze(try function("func cancelResting(_ target: PerplOpenOrder, tapRq: Int?, chainOrder: ChainOrderKey, account: ActionAccount, title: String,", in: trading))
        // Only the sending socket's whole list, not suspect, can say the order is no longer the one the user saw.
        assertOrder(cancel, ["try self.requireAction(account, on: client)",
                             "guard client.signedIn, client.hasOrdersSnapshot, !client.streamSuspect else { throw OrdersNotChecked() }",
                             "client.openOrders.first(", "listed.contractOrderId == target.contractOrderId", "listed.typeRaw == target.typeRaw",
                             "client.requestId(for: target.id) == tapRq else { listedGone = true; return false }",
                             "cancelAndConfirm(orders: [target], approval: approval, onAcks: { acks in", "}, check: stillTheOrder)"])
        XCTAssertFalse(cancel.contains("sendEach("), "nothing sent but through cancelAndConfirm")
        XCTAssertTrue(cancel.contains("guard let result = results[target.id] else { // Not the order the user saw any more, by that socket's whole list: it left Perpl's list (or its id now names // another order). Nothing sent. guard listedGone else { return .notConfirmed } let gone = CancelResult.alreadyGone"))
        // Not a refusal of the route: the list is back in a moment (no `noteAPIRefusal`, no wallet line).
        XCTAssertFalse(squeeze(try function("struct OrdersNotChecked: LocalizedError {", in: trading)).contains("PerplTradeError"))
        XCTAssertFalse(squeeze(try function("struct OrdersNotChecked: LocalizedError {", in: trading)).contains("noteAPIRefusal"))
        XCTAssertTrue(cancel.contains("if result == .cancelled, let owner = account.owner { Activity.record(ActivityRecord(kind: .perp, title: title, subtitle: subtitle, hash: nil, section: \"perps\"), owner: owner) }"))
        XCTAssertTrue(cancel.contains("if result.isGone { goneChainOrders[chainOrder] = (result, Date()) }"))
        XCTAssertEqual(cancel.components(separatedBy: "goneChainOrders[").count - 1, 2, "only for a result that is gone")
        let confirm = squeeze(try function("func cancelAndConfirm(orders: [PerplOpenOrder], approval: MeraSession.StepUp? = nil,", in: trading))
        // A socket that just signed in sends its list before the check reads it (bounded, inside the drain's cap).
        assertOrder(confirm, ["try requireCancelApproval(approval)", "let client = try liveClient()", "if let check {",
                              "let deadline = Date().addingTimeInterval(PerplTimeouts.ordersSnapshot)",
                              "while client.signedIn, !client.hasOrdersSnapshot, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }",
                              "if try !check(client) { return [:] }", "sendCancels(orders, on: client)"])
        // The stream's word that an order's scid left its list stands only while the list is live and not suspect, and only for
        // a short while (the Exchange gives the id again); a cancel from this device is kept by the chain order's terms.
        let gone = squeeze(try function("func chainOrderGone(_ order: PerpOrder) -> ChainOrderGone? {", in: trading))
        assertOrder(gone, ["$0.contractOrderId == order.orderId }) { return nil }", "goneChainOrders[ChainOrderKey(order)]", "Self.goneWindow",
                           "byCancel: true", "guard ordersAreLive, !streamSuspect, let client, let left = client.lastTerminalStatus(marketId: order.perpId, contractOrderId: order.orderId),",
                           "Date().timeIntervalSince(left.at) < Self.scidGoneWindow else { return nil }", "byCancel: false"])
        XCTAssertTrue(squeeze(trading).contains("init(_ order: PerpOrder) { perpId = order.perpId; orderId = order.orderId; side = order.side; price = order.price; size = order.size }"))
        XCTAssertTrue(trading.contains("static let scidGoneWindow: TimeInterval = 30"))
    }

    /// The Cancel Order sheet (A.4.2): `cancelResting` behind the wallet sheet's own App Lock (fail closed without a
    /// passcode), its rows in words agreeing with "order", Perpl's generic refusal said once, Try Again only while Perpl
    /// still lists the order, a haptic and an announcement for each result.
    func testTheCancelOrderSheet() throws {
        let sheet = try section(try DocsLinksTests.appSource("Perps/PerpTriggerSheets.swift"), from: "struct CancelOrderSheet: View {", to: "private struct CancelTriggerRow: View {")
        let squeezed = squeeze(sheet)
        XCTAssertTrue(squeezed.contains("try await perplTrading.cancelResting(target, tapRq: tapRq, chainOrder: PerplTrading.ChainOrderKey(order), account: account,"))
        assertOrder(squeezed, ["guard BiometricGate.canAuthenticateOwner else {", "let action = tr(\"Cancel Order\")",
                               "guard await BiometricGate.authenticate(reason: \"Confirm \\(action)\") else {", "apiPhase = .cancelling"])
        XCTAssertTrue(squeezed.contains("guard settled, failureLine == nil, perplTrading.ordersAreLive, perplTrading.openOrders.contains(where: { $0.id == target.id }) else { return false }"))
        XCTAssertTrue(squeezed.contains("why == PerplOrderReason(status: 7, reason: 45).message ? PerpActionCopy.orderCouldntCancelGeneric : PerpActionCopy.orderCouldntCancel(why)"))
        XCTAssertFalse(sheet.contains("rowCancelled") || sheet.contains("rowStillLive"), "the order's own words")
        XCTAssertTrue(sheet.contains("PerpActionCopy.orderCancelled") && sheet.contains("PerpActionCopy.orderStillLive"))
        XCTAssertTrue(sheet.contains(".sensoryFeedback(") && sheet.contains("AccessibilityNotification.Announcement("))
        XCTAssertTrue(squeezed.contains(".onChange(of: perplTrading.openOrders) { _, _ in guard apiPhase == .cancelling, let confirmed = perplTrading.cancelLiveResult(target.id) else { return }"))
        XCTAssertFalse(sheet.contains("Activity.record"), "PerplTrading records a confirmed cancel")
        // A list that isn't there yet to check the order against refuses nothing of the route: no wallet line.
        XCTAssertTrue(squeezed.contains("let onDevice = (error as? PerplTradeError)?.isInvalidOrder == true || error is PerplTrading.OrdersNotChecked"))
        XCTAssertTrue(squeezed.contains("failureLine = onDevice ? nil : perplTrading.nothingSentLine(for: account)"))
        let copy = try DocsLinksTests.appSource("Perps/PerpOrderOutcomeView.swift")
        for key in ["cancelled", "stillLive", "filledFirst", "expiredFirst", "alreadyGone", "notConfirmed"] {
            XCTAssertTrue(copy.contains("\"cancelRow.order.\(key)\""), key)
        }
    }

    /// A gone order's card offers no Cancel; a close's notice names the position; a close Perpl never answered says it
    /// may have gone through on the status row.
    func testTheCardsNoticesAndStatusRow() throws {
        let trade = try trade
        let card = squeeze(try section(trade, from: "struct OrderCard: View {", to: "/// A TP/SL row to display"))
        assertOrder(card, ["if let gone {", "} else if cancelling {", "} else { Button(\"Cancel\", action: onCancel)"])
        // The "… first" words only for a cancel this device sent; an order that left on its own is said to have left, plainly.
        XCTAssertTrue(card.contains("Text(verbatim: gone.byCancel ? PerpActionCopy.orderState(gone.result) : PerpActionCopy.orderLeft(gone.result))"))
        let copy = try DocsLinksTests.appSource("Perps/PerpOrderOutcomeView.swift")
        let left = squeeze(try function("static func orderLeft(_ result: PerplCancelResult) -> String {", in: copy))
        for word in ["orderFilledFirst", "orderExpiredFirst", "orderAlreadyGone", "orderNotConfirmed", "orderStillLive"] { XCTAssertFalse(left.contains(word), word) }
        for key in ["filled", "expired", "gone"] { XCTAssertTrue(copy.contains("\"orderCard.\(key)\""), key) }
        XCTAssertTrue(squeeze(trade).contains("gone: perplTrading.chainOrderGone(order), onCancel: { tapCancel(order) })"))
        let tracker = squeeze(try DocsLinksTests.appSource("Wallet/PerplOrderTracker.swift"))
        XCTAssertTrue(tracker.contains("let position = PerpAlertText.positionName(asset: asset, side: order.closes ?? order.side.opposite) Notifications.perpClose("))
        let row = squeeze(try DocsLinksTests.appSource("Perps/PerpOrderOutcomeView.swift"))
        XCTAssertTrue(row.contains("if !order.acknowledged, order.isClose { return PerpActionCopy.closeUnknown }"))
        XCTAssertTrue(row.contains("order.isClose ? PerplOutcomeText.close(entry, order.textContext) : PerplOutcomeText.order(entry, order.textContext)"))
    }

    /// The scripted demo (p4 spec D, D.3): compiled into DEBUG Simulator builds only; no socket, no key, no network; its own
    /// session, never the app's; nothing filed or posted; no string of it in the shipped catalog.
    func testTheDemoIsIsolated() throws {
        let demo = try DocsLinksTests.appSource("Debug/PerpsDemo.swift")
        let code = demo.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        XCTAssertEqual(code.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "#if DEBUG && targetEnvironment(simulator)", "the whole file is DEBUG + Simulator")
        XCTAssertEqual(code.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "#endif")
        XCTAssertEqual(demo.components(separatedBy: "#if ").count - 1, 1, "one condition, the file's")
        XCTAssertTrue(demo.contains("PerplTrading(mera: nil)"), "its own session, bound to no passkey")
        XCTAssertTrue(demo.contains("ActionAccount(owner: nil"), "no wallet: nothing is filed under anyone")
        for banned in [".refresh(", ".connect(", ".enroll(", "ensureConnected(", "PerplKeychain", "URLSession", "env.sender", "run.start", "env.perpl.",
                       "Activity.record", "Notifications.", "env.perplTrading", "UserDefaults"] {
            XCTAssertFalse(demo.contains(banned), banned)
        }
        // No string of it reaches the catalog (strings-sync reads a DEBUG build).
        for literal in ["Button(\"", "navigationTitle(\"", "Section(\"", "Label(\"", "Toggle(\"", "Text(\""] {
            XCTAssertFalse(demo.contains(literal), literal)
        }
        // Every sheet it presents takes the trading connection: an account for Close / Add Margin / Cancel Order, the live order sheet.
        let squeezed = squeeze(demo)
        XCTAssertTrue(squeezed.contains("live: true, closes: nil"))
        XCTAssertTrue(squeezed.contains("ClosePositionSheet(market: market, position: position, mark: market.mark, accountId: Script.accountId, route: PerpsDemo.account)"))
        XCTAssertTrue(squeezed.contains("AddMarginSheet(market: market, position: position, available: demo.scenario.available, accountId: Script.accountId, route: PerpsDemo.account)"))
        XCTAssertTrue(squeezed.contains("tapRq: tapRq, account: PerpsDemo.account)"))
        XCTAssertTrue(squeezed.contains("trading.readPositions = { _, _ in socket.chainPositions() }"), "the chain reads are the script's")
        XCTAssertTrue(squeezed.contains("TriggerStore.remove(perpId: Script.marketId, kind: kind, positionLong: long, owner: session.address)"), "the echoes go on exit")

        // Outside the demo file, every use of the demo sits inside `#if DEBUG && targetEnvironment(simulator)` (its release
        // stub `demoReadOwner`, which is nil, aside).
        let tokens = ["PerpsDemo", "perpsDemoAutoConfirm", "perpsDemoTerms", "perpsDemoTryAgain", "debugAdopt", "debugRelease", "isDemo", "debugNotices",
                      "debugNotice", "debugScripted", "debugAttach", "debugReceive", "debugDrop"]
        for (path, text) in try FormattedTextIsolationTests.appSources() where !path.hasPrefix("Debug/") {
            var depth = 0, demoDepth: Int?
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if ") {
                    depth += 1
                    if trimmed == "#if DEBUG && targetEnvironment(simulator)", demoDepth == nil { demoDepth = depth }
                } else if trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif") {
                    if demoDepth == depth { demoDepth = nil }
                } else if trimmed.hasPrefix("#endif") {
                    if demoDepth == depth { demoDepth = nil }
                    depth -= 1
                } else if demoDepth == nil, let token = tokens.first(where: { line.contains($0) }) {
                    XCTFail("\(path): \(token) outside the demo's #if: \(trimmed)")
                }
            }
        }
        let trading = try trading
        XCTAssertTrue(squeeze(trading).contains("#else /// Nil outside the DEBUG demo. var demoReadOwner: Address? { nil }"), "the release stub returns nil")
        let adopt = squeeze(try function("func debugAdopt(_ client: PerplTradeClient) {", in: trading))
        assertOrder(adopt, ["precondition(client.isDebugScripted && key == nil && boundAddress == nil", "wire(client)", "client.onRequestIdIssued = nil",
                            "self.client = client"])
        let release = squeeze(try function("func debugRelease() {", in: trading))
        XCTAssertTrue(release.contains("_ = client?.drainCensus()"), "its counts never reach the owner's census")
        XCTAssertFalse(release.contains("flushCensus"))
        // The connect callbacks live in one place, used by the real connect and the demo's adoption alike.
        let connect = squeeze(try function("private func performConnect() async throws {", in: trading))
        XCTAssertTrue(connect.contains("let client = PerplTradeClient(key: key, chainId: Monad.chainId) wire(client) self.client = client"))
        XCTAssertEqual(trading.components(separatedBy: "client.onDisconnect = {").count - 1, 1)
        XCTAssertTrue(squeeze(try function("private func syncStatus() {", in: trading)).contains("if let id = client.accountId, !demoSession { PerplForwardingMemory.record("))
        // The kit's demo client never connects, and can't route.
        var kit = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { kit.deleteLastPathComponent() }
        let client = try String(contentsOf: kit.appendingPathComponent("Sources/DyorKit/Services/Perpl/PerplTradeClient.swift"), encoding: .utf8)
        let connectBody = squeeze(try function("public func connect(timeout: TimeInterval = 10) async throws {", in: client))
        XCTAssertTrue(connectBody.hasPrefix("public func connect(timeout: TimeInterval = 10) async throws { #if DEBUG precondition(!isDebugScripted, \"a scripted demo client never connects\") #endif"))
        XCTAssertTrue(client.contains("URL(string: \"wss://perps-demo.invalid\")!"))
        let script = try String(contentsOf: kit.appendingPathComponent("Sources/DyorKit/Services/Perpl/PerplDemoScript.swift"), encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#if DEBUG\n"))
        XCTAssertTrue(script.hasSuffix("#endif\n"))
        // The sheets confirm themselves only in the demo, through their own confirm.
        let sheets = try DocsLinksTests.appSource("Perps/PerpTriggerSheets.swift")
        for text in [try trade, sheets] {
            for task in text.components(separatedBy: "#if DEBUG && targetEnvironment(simulator)").dropFirst() {
                let block = squeeze(task.components(separatedBy: "#endif").first ?? "")
                if block.contains("demoAutoConfirm") && block.contains(".task {") { XCTAssertTrue(block.contains("perplTrading.isDemo"), block) }
            }
        }
        // The tracker posts nothing for an order with no account: the demo's would-be notice goes to its list.
        let tracker = try DocsLinksTests.appSource("Wallet/PerplOrderTracker.swift")
        let announce = squeeze(String(tracker[try XCTUnwrap(tracker.range(of: "case .announce(let notice, let banner):")).upperBound...].prefix(1400)))
        assertOrder(announce, ["#if DEBUG && targetEnvironment(simulator) if order.owner == nil, let debugNotice {", "#endif", "if order.owner == nil { break }", "Notifications."])
    }
}
