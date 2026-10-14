import DyorKit
import SwiftUI

/// Sets, moves or removes an open position's take-profit and stop-loss on Perpl (security audit GT-1). A new trigger is
/// linked to the position (`lp`), so Perpl cancels it when the position closes, and closes the position's whole size as
/// the trading stream reports it now. That size is fixed — it won't follow the position if it grows or shrinks later —
/// and the sheet says so (GT-5). Moving a trigger cancels the old one first, then places the new one once Perpl's list
/// confirms the cancel; every step's outcome is shown, and a gap it leaves is said plainly.
struct PositionTriggersSheet: View {
    let market: PerpMarket
    let position: PerpPosition
    let mark: Double
    let onDone: () -> Void

    @Environment(PerplTrading.self) private var perplTrading
    @Environment(AppSettings.self) private var settings
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var tpText = ""
    @State private var slText = ""
    @State private var removeTP = false
    @State private var removeSL = false
    @State private var phase: TriggerSheetPhase = .editing
    /// What each kind is doing while the change runs (I42).
    @State private var steps: [PerplTriggerKind: PerplTrading.TriggerChangeStep] = [:]

    private var isLong: Bool { position.side == .long }
    private var live: [PerplOpenOrder] {
        perplTrading.openOrders.filter { $0.marketId == market.id && $0.isTrigger && $0.isReduceOnly && $0.protectsLong == isLong }
    }
    private var currentTP: [PerplOpenOrder] { live.filter { !$0.isStopLoss } }
    private var currentSL: [PerplOpenOrder] { live.filter(\.isStopLoss) }
    private var livePosition: PerplLivePosition? {
        perplTrading.livePositions.first { $0.marketId == market.id && $0.isLong == isLong && $0.isOpen }
    }
    private var liveSize: Double? { livePosition.map { Double($0.sizeRaw) / pow(10, Double(market.lotDecimals)) } }

    /// Why nothing can be changed from here right now, if so, in the app's language.
    private var unavailable: String? {
        if !session.canSign { return SessionError.readOnly.localizedDescription }
        if !perplTrading.ordersAreLive {
            return perplTrading.isEnrolled
                ? tr("Perpl trading isn't connected, so this position's current TP/SL can't be read. Reconnect in Profile → Perpl Trading.")
                : tr("Connect Perpl trading in Profile to set take-profit and stop-loss.")
        }
        if perplTrading.status == .needsForwarding { return tr("Enable one-click trading in Profile to set take-profit and stop-loss.") }
        if livePosition == nil { return tr("Perpl hasn't reported this position on the trading connection yet. Try again in a moment.") }
        return nil
    }

    private var changes: [PerplTrading.TriggerChange] {
        var out: [PerplTrading.TriggerChange] = []
        for (kind, text, remove, current) in [(PerplTriggerKind.stopLoss, slText, removeSL, currentSL), (.takeProfit, tpText, removeTP, currentTP)] {
            if remove, !current.isEmpty { out.append(.init(kind: kind, price: nil, replacing: current)) }
            else if !remove, let price = text.perpDouble { out.append(.init(kind: kind, price: price, replacing: current)) }
        }
        return out
    }

    /// What's wrong with a typed trigger, in the app's language.
    private var problem: String? {
        for (kind, text, remove) in [(PerplTriggerKind.takeProfit, tpText, removeTP), (.stopLoss, slText, removeSL)] where !remove {
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, text.perpDouble == nil {
                return kind == .takeProfit ? tr("Enter the take-profit as a number.") : tr("Enter the stop-loss as a number.")
            }
        }
        for change in changes {
            guard let price = change.price else { continue }
            if change.kind == .stopLoss, market.maintMarginFraction == nil { return PerplTriggerRules.liquidationUnknownMessage }
            if let problem = PerplTriggerRules.problem(change.kind, price: price, side: position.side, reference: mark, liquidation: position.liquidation, priceDecimals: market.priceDecimals) {
                return problem.message(market: market, referenceName: PerplTrading.markPriceName)
            }
        }
        return nil
    }

    private var busy: Bool { phase == .working }
    private var finished: Bool { if case .finished = phase { return true }; return false }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow("Position", verbatim: PositionText.amount(isLong: isLong, size: position.size, asset: market.asset), tint: isLong ? .positive : .negative)
                    DetailRow("Mark price", NumberStyle.number(mark))
                    DetailRow("Liq. price", verbatim: position.liquidation.map { NumberStyle.number($0) } ?? PositionText.unknown)
                }
                triggerSection(.stopLoss, text: $slText, remove: $removeSL, current: currentSL)
                triggerSection(.takeProfit, text: $tpText, remove: $removeTP, current: currentTP)
                Section {
                    if let liveSize {
                        Paragraph("A new take-profit or stop-loss closes \(NumberStyle.number(liveSize)) \(market.asset), the whole position as it is now. That size is fixed: if you add to or reduce the position later, set TP/SL again. It is cancelled automatically when the position closes.")
                    }
                    Paragraph("Moving one cancels the old trigger first, and places the new one once Perpl confirms the cancel.")
                }
                .font(.footnote).foregroundStyle(.secondary)
                if session.isPasskeyAccount, !finished, !changes.isEmpty {
                    // A cancel and a reduce-only close always ask (MERA-PLAN §3): one Face ID covers the whole change.
                    let cancels = changes.contains { !$0.replacing.isEmpty }
                    Section { SessionScopeBadge(assessment: .faceID((cancels ? Mera.AlwaysAsk.cancelOrder : Mera.AlwaysAsk.closePosition).summary)) }
                }
                if let unavailable, !finished {
                    Section { InlineError(message: unavailable) }.listRowBackground(Color.clear)
                } else if let problem, !finished {
                    Section { InlineError(message: problem) }.listRowBackground(Color.clear)
                }
                if busy, !steps.isEmpty {
                    Section {
                        // Stop-loss first, as the change runs.
                        ForEach([PerplTriggerKind.stopLoss, .takeProfit], id: \.self) { kind in
                            if let step = steps[kind] {
                                Label { Paragraph(verbatim: PerpTriggerCopy.step(kind, step)) } icon: { ProgressView().controlSize(.mini) }
                                    .modifier(ParagraphLabel())
                                    .font(.footnote)
                            }
                        }
                    }
                }
                TriggerSheetOutcomeSection(phase: phase)
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("TP/SL · \(market.asset)-PERP"))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? "Done" : "Cancel") { close() }.disabled(busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !finished {
                    PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : "Save TP/SL", isBusy: busy,
                                  isDisabled: unavailable != nil || problem != nil || changes.isEmpty) {
                        Task { await apply() }
                    }
                    .padding().frame(maxWidth: .infinity).background(.bar)
                }
            }
            .interactiveDismissDisabled(busy)
        }
        .presentationDetents([.large])
        .presentationBackground(Color(.systemGroupedBackground))
    }

    /// Each kind's text is written whole (a key of its own), never a kind's name put into another sentence.
    @ViewBuilder
    private func triggerSection(_ kind: PerplTriggerKind, text: Binding<String>, remove: Binding<Bool>, current: [PerplOpenOrder]) -> some View {
        let isTP = kind == .takeProfit
        Section {
            if current.isEmpty {
                Text("None on Perpl").foregroundStyle(.secondary)
            } else {
                ForEach(current) { order in
                    DetailRow("Now", describeTrigger(order))
                }
            }
            HStack {
                Text(current.isEmpty ? "Set at" : "Move to").foregroundStyle(.secondary)
                Spacer()
                TextField(current.isEmpty ? "Optional" : "Keep", text: text)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                    .disabled(remove.wrappedValue || busy || finished)
                    .accessibilityLabel(isTP ? "Take profit price, USD" : "Stop loss price, USD")
                Text("USD").foregroundStyle(.secondary)
            }
            if !current.isEmpty {
                Toggle(isTP ? "Remove take profit" : "Remove stop loss", isOn: remove).disabled(busy || finished)
            }
        } header: {
            Text(isTP ? "Take profit" : "Stop loss")
        } footer: {
            if current.count > 1 {
                Paragraph(isTP ? "\(current.count) take profits are live. A new one replaces all of them."
                          : "\(current.count) stop losses are live. A new one replaces all of them.")
            }
        }
    }

    private func describeTrigger(_ order: PerplOpenOrder) -> String {
        let price = Double(order.triggerPriceRaw ?? 0) / pow(10, Double(market.priceDecimals))
        let size = Double(order.sizeRaw) / pow(10, Double(market.lotDecimals))
        return "\(NumberStyle.number(price)) · \(NumberStyle.number(size)) \(market.asset)"
    }

    private func close() {
        let reload = finished
        dismiss()
        if reload { onDone() }
    }

    /// `approval`: a passkey account's step-up for this one change, when the session asked for one.
    private func apply(approval: MeraSession.StepUp? = nil) async {
        // App Lock covers this like an order: it cancels and places triggers with the Perpl API key.
        if approval == nil, settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm TP/SL")) { return }
        // Re-read on the retry after Face ID too: the position can close, or the stream reconnect, while the prompt is
        // open. Never left busy — the sheet couldn't be closed.
        guard let livePosition else {
            if phase == .working { phase = .failed(tr("This position is no longer on Perpl's live list, so nothing was changed. Check Positions, then try again.")) }
            return
        }
        let changes = self.changes
        guard !changes.isEmpty else {
            if phase == .working { phase = .failed(tr("The TP/SL on Perpl changed meanwhile, so nothing was sent. Check them and try again.")) }
            return
        }
        phase = .working
        steps = [:]
        defer { steps = [:] }
        do {
            let outcomes = try await perplTrading.changeTriggers(changes, market: market, position: livePosition, reference: mark, liquidation: position.liquidation,
                                                                 approval: approval) { kind, step in steps[kind] = step }
            let size = Double(livePosition.sizeRaw) / pow(10, Double(market.lotDecimals))
            var lines: [TriggerSheetLine] = []
            var summary: [String] = []
            for change in changes {
                guard let outcome = outcomes[change.kind] else { continue }
                lines.append(line(for: change, outcome: outcome, size: size))
                let kind = PlacedTrigger.Kind(change.kind)
                switch outcome {
                case .placed, .placementUnknown, .placementNotConfirmed:
                    if !change.replacing.isEmpty { TriggerStore.remove(perpId: market.id, kind: kind, positionLong: isLong, owner: session.address) }
                    // One that went unanswered, or that Perpl admitted but didn't list in time, may be live too, so this
                    // device keeps a record of it as well — shown as unverified until Perpl's list confirms or drops it
                    // (GT-3), as the order sheet does.
                    if let price = change.price {
                        TriggerStore.record([PlacedTrigger(perpId: market.id, symbol: market.asset, kind: kind, price: price, size: size, positionLong: isLong)], owner: session.address)
                        if outcome == .placed { summary.append(PositionText.trigger(change.kind == .takeProfit, at: price)) }
                    }
                case .placedTriggeredAtOnce:
                    // Admitted like a placed one, but it already fired: no "set" in the summary, and nothing armed is
                    // left to keep a record of.
                    if !change.replacing.isEmpty { TriggerStore.remove(perpId: market.id, kind: kind, positionLong: isLong, owner: session.address) }
                case .removed, .unprotected:
                    if !change.replacing.isEmpty { TriggerStore.remove(perpId: market.id, kind: kind, positionLong: isLong, owner: session.address) }
                    if outcome == .removed { summary.append(change.kind == .takeProfit ? tr("TP removed") : tr("SL removed")) }
                case .unchanged, .partlyRemoved, .cancelUnknown, .cancelNotConfirmed:
                    break
                }
            }
            phase = .finished(lines)
            if !summary.isEmpty {
                let name = PerplTrading.positionName(market: "\(market.asset)-PERP", isLong: isLong)
                Activity.record(ActivityRecord(kind: .perp, title: tr("TP/SL updated"), subtitle: "\(name) · \(summary.joined(separator: " · "))", hash: nil, section: "perps"), owner: session.address)
            }
        } catch is MeraSession.StepUpRequired where approval == nil {
            do {
                let approval = try await session.mera.stepUp()
                await apply(approval: approval)
            } catch where isUserCancellation(error) {
                phase = .failed(tr("Nothing was changed."))
            } catch {
                phase = .failed(describe(error))
            }
        } catch {
            phase = .failed(describe(error))
        }
    }

    /// A step's outcome in the app's language. Each kind's sentence is written whole (a key of its own), never a kind's
    /// name put into another sentence; `why` is Perpl's own reason, or the app's when Perpl gave none.
    private func line(for change: PerplTrading.TriggerChange, outcome: PerplTrading.TriggerChangeOutcome, size: Double) -> TriggerSheetLine {
        let tp = change.kind == .takeProfit
        let price = change.price.map { NumberStyle.number($0) } ?? ""
        let closing = "\(NumberStyle.number(size)) \(market.asset)"
        let fresh = change.replacing.isEmpty
        switch outcome {
        case .placed:
            let text = fresh
                ? (tp ? tr("Take-profit set at \(price), closing \(closing).") : tr("Stop-loss set at \(price), closing \(closing)."))
                : (tp ? tr("Take-profit moved to \(price), closing \(closing). The old one was cancelled.")
                      : tr("Stop-loss moved to \(price), closing \(closing). The old one was cancelled."))
            return TriggerSheetLine(text: text, warning: false)
        case .removed:
            return TriggerSheetLine(text: tp ? tr("Take-profit removed.") : tr("Stop-loss removed."), warning: false)
        case .unchanged(let why):
            let text = fresh
                ? (tp ? tr("Take-profit not placed: \(why)") : tr("Stop-loss not placed: \(why)"))
                : (tp ? tr("Take-profit not changed: \(why) The old one is still live.") : tr("Stop-loss not changed: \(why) The old one is still live."))
            return TriggerSheetLine(text: text, warning: true)
        case .partlyRemoved(let why):
            return TriggerSheetLine(text: tp
                ? tr("Some of the old take-profits were cancelled, but one was refused and is still live (\(why)). The new one wasn't placed. Check Orders.")
                : tr("Some of the old stop-losses were cancelled, but one was refused and is still live (\(why)). The new one wasn't placed. Check Orders."), warning: true)
        case .cancelUnknown:
            return TriggerSheetLine(text: tp
                ? tr("Perpl didn't confirm cancelling the old take-profit, so the new one wasn't placed. Check Orders before trying again.")
                : tr("Perpl didn't confirm cancelling the old stop-loss, so the new one wasn't placed. Check Orders before trying again."), warning: true)
        case .cancelNotConfirmed:
            let text = change.price == nil
                ? (tp ? tr("Cancel sent for the take-profit, but Perpl hasn't confirmed it. Check Orders: it may still be live.")
                      : tr("Cancel sent for the stop-loss, but Perpl hasn't confirmed it. Check Orders: it may still be live."))
                : (tp ? tr("Cancel sent for the old take-profit, but Perpl hasn't confirmed it, so the new one wasn't placed (that could leave two). Check Orders: if the old one is gone, this position has no take-profit now.")
                      : tr("Cancel sent for the old stop-loss, but Perpl hasn't confirmed it, so the new one wasn't placed (that could leave two). Check Orders: if the old one is gone, this position has no stop-loss now."))
            return TriggerSheetLine(text: text, warning: true)
        case .unprotected(let why):
            return TriggerSheetLine(text: tp
                ? tr("The old take-profit was cancelled, but Perpl refused the new one (\(why)). This position has no take-profit now.")
                : tr("The old stop-loss was cancelled, but Perpl refused the new one (\(why)). This position has no stop-loss now."), warning: true)
        case .placementUnknown:
            let text = fresh
                ? (tp ? tr("Order status unknown — Perpl didn't confirm the new take-profit. Check Open Orders before placing it again.")
                      : tr("Order status unknown — Perpl didn't confirm the new stop-loss. Check Open Orders before placing it again."))
                : (tp ? tr("Order status unknown — Perpl didn't confirm the new take-profit. The old one was cancelled. Check Open Orders before placing it again.")
                      : tr("Order status unknown — Perpl didn't confirm the new stop-loss. The old one was cancelled. Check Open Orders before placing it again."))
            return TriggerSheetLine(text: text, warning: true)
        case .placementNotConfirmed:
            return TriggerSheetLine(text: PerpTriggerCopy.notListed(change.kind, replacing: !fresh), warning: true)
        case .placedTriggeredAtOnce:
            return TriggerSheetLine(text: PerpTriggerCopy.triggeredAtOnce(change.kind, price: price), warning: true)
        }
    }
}

/// Cancels keeper triggers (TP/SL) on Perpl: one the user picked from the Orders list, or the ones left over on a
/// market with no position for them to close (security audit GT-1, GT-2). Every row stays where it is and says, as it
/// happens, what Perpl did with its cancel: cancelling, then cancelled once it has left Perpl's live list — or still
/// live (Perpl refused the cancel), already gone, triggered or expired first, or not confirmed in time. Nothing reads as
/// cancelled before Perpl's list shows it. Once the cancels are out the sheet can be closed: PerplTrading finishes the
/// wait and records what Perpl confirmed.
struct CancelTriggersSheet: View {
    let market: PerpMarket
    let orders: [PerplOpenOrder]
    /// The sheet's title and the note under the list, resolved in the app's language (`tr()`).
    let title: LocalizedStringResource
    var note: LocalizedStringResource?
    let onDone: () -> Void

    @Environment(PerplTrading.self) private var perplTrading
    @Environment(AppSettings.self) private var settings
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// Each row's state, by its order: what Perpl's list showed of its cancel.
    @State private var rows: [PerplOpenOrder.Key: RowState] = [:]
    /// App Lock, the step-up and the sends (seconds at most): the sheet can't be closed meanwhile (I30b).
    @State private var busy = false
    /// A cancel went out: the button is gone, and closing reloads the screen behind.
    @State private var sent = false
    /// The last wait for Perpl's list is over: its sentences show, and Try Again where it can help.
    @State private var settled = false
    /// Why nothing was sent.
    @State private var failure: String?
    /// Bumped as each wait ends, for its haptic.
    @State private var waits = 0
    #if DEBUG && targetEnvironment(simulator)
    @Environment(\.perpsDemoAutoConfirm) private var demoAutoConfirm
    #endif

    /// A row's state: ready to cancel, its cancel on its way, or what Perpl's live list showed of it.
    enum RowState: Equatable {
        case ready, cancelling, cancelled, stillLive(String), alreadyGone, firedFirst, expiredFirst, notConfirmed

        init(_ result: PerplTrading.CancelResult) {
            switch result {
            case .cancelled: self = .cancelled
            case .firedFirst: self = .firedFirst
            case .expiredFirst: self = .expiredFirst
            case .alreadyGone: self = .alreadyGone
            case .refused(let why): self = .stillLive(why)
            case .notConfirmed: self = .notConfirmed
            }
        }
    }

    private var anyCancelling: Bool { rows.values.contains(.cancelling) }
    private var unavailable: String? {
        if !session.canSign { return SessionError.readOnly.localizedDescription }
        if !perplTrading.ordersAreLive { return tr("Perpl trading isn't connected. Reconnect in Profile → Perpl Trading to cancel.") }
        if perplTrading.status == .needsForwarding { return tr("Enable one-click trading in Profile to cancel from the app.") }
        return nil
    }

    /// What a retry may cancel again (I20): only after the wait, only rows whose cancel was refused or not confirmed, and
    /// only while Perpl's live list still has them — never one that left it.
    private var retryable: [PerplOpenOrder] {
        guard settled, !busy, perplTrading.ordersAreLive else { return [] }
        return perplTrading.openOrders.filter { listed in
            switch rows[listed.id] {
            case .stillLive(_)?, .notConfirmed?: return true
            default: return false
            }
        }
    }

    /// The outcome's sentences: how many Perpl's list confirmed cancelled, then one for each row that wasn't.
    private var lines: [TriggerSheetLine] {
        var lines: [TriggerSheetLine] = []
        let cancelled = orders.filter { rows[$0.id] == .cancelled }.count
        if cancelled > 0 { lines.append(TriggerSheetLine(text: PerpTriggerCopy.cancelled(count: cancelled), tone: .success)) }
        lines += orders.compactMap { order in rows[order.id].flatMap { PerpTriggerCopy.line(for: order, state: $0, market: market) } }
        return lines
    }

    /// The wait's result, felt: all cancelled, a success; any still live, an error; anything else, a warning.
    private var feedback: SensoryFeedback {
        let states = orders.compactMap { rows[$0.id] }
        if !states.isEmpty, states.allSatisfy({ $0 == .cancelled }) { return .success }
        if states.contains(where: { if case .stillLive = $0 { return true } else { return false } }) { return .error }
        return .warning
    }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orders) { order in
                        CancelTriggerRow(order: order, market: market, state: rows[order.id] ?? .ready)
                    }
                } header: {
                    Text(orders.first?.protectsLong == false ? "\(market.asset)-PERP · on Short" : "\(market.asset)-PERP · on Long")
                } footer: {
                    if let note { Text(verbatim: tr(note)) }
                }
                if session.isPasskeyAccount, !sent || !retryable.isEmpty {
                    Section { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.cancelOrder.summary)) }
                }
                if let unavailable, !sent {
                    Section { InlineError(message: unavailable) }.listRowBackground(Color.clear)
                }
                TriggerSheetOutcomeSection(phase: settled ? .finished(lines) : .editing)
                if !retryable.isEmpty {
                    Section {
                        Button("Try Again") { Task { await apply(keys: Set(retryable.map(\.id))) } }
                            .buttonStyle(.bordered)
                    }
                    .listRowBackground(Color.clear)
                }
                if let failure {
                    Section { InlineError(message: failure) }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent && !anyCancelling ? "Done" : "Close") { close() }.disabled(busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !sent {
                    PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : (orders.count == 1 ? "Cancel Trigger" : "Cancel \(orders.count) Triggers"),
                                  isBusy: busy, isDisabled: unavailable != nil || orders.isEmpty, foreground: .onStatus) {
                        Task { await apply() }
                    }
                    .tint(.negative)
                    .padding().frame(maxWidth: .infinity).background(.bar)
                }
            }
            .interactiveDismissDisabled(busy)
            .onChange(of: perplTrading.openOrders) { _, _ in flipConfirmed() }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(trigger: waits) { _, _ in feedback }
        #if DEBUG && targetEnvironment(simulator)
        // The scripted Perps demo only (`PerpsDemo`): with Run, this sheet's own confirm 2 s after it appears (App Lock
        // still asks).
        .task {
            guard perplTrading.isDemo, let demoAutoConfirm else { return }
            try? await Task.sleep(for: demoAutoConfirm)
            if !sent, !busy { await apply() }
        }
        #endif
    }

    private func close() {
        dismiss()
        if sent { onDone() }
    }

    /// A cancel Perpl's list confirms flips its row at once, before the wait ends — only from the socket that sent it,
    /// and only once the order left that list with a status saying how (I9).
    private func flipConfirmed() {
        for order in orders where rows[order.id] == .cancelling {
            guard let result = perplTrading.cancelLiveResult(order.id) else { continue }
            withAnimation { rows[order.id] = RowState(result) }
        }
    }

    /// Cancels the rows (`keys`: a retry's, else all of them): App Lock, then a passkey account's step-up — every run asks
    /// again (MERA-PLAN §3) — then PerplTrading sends the cancels and follows each to Perpl's live list.
    private func apply(approval: MeraSession.StepUp? = nil, keys: Set<PerplOpenOrder.Key>? = nil) async {
        if approval == nil, settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Cancel TP/SL")) { return }
        // A retry cancels what Perpl's live list still has; the first run, what the sheet was opened for.
        let targets = keys.map { keys in perplTrading.openOrders.filter { keys.contains($0.id) } } ?? orders
        guard !targets.isEmpty else { return }
        let before = rows
        let wasSettled = settled
        busy = true
        failure = nil
        settled = false
        withAnimation { for order in targets { rows[order.id] = .cancelling } }
        do {
            let results = try await perplTrading.cancelAndConfirm(orders: targets, approval: approval) { acks in
                busy = false // every cancel is out: the sheet can be closed while Perpl's list confirms them
                sent = true
                withAnimation { for (key, result) in acks { rows[key] = RowState(result) } }
                // Perpl's list may have confirmed some already, before their acks were in.
                flipConfirmed()
            }
            withAnimation { for (key, result) in results { rows[key] = RowState(result) } }
            busy = false
            settled = true
            waits += 1
            if let summary = lines.first?.text { AccessibilityNotification.Announcement(summary).post() }
        } catch is MeraSession.StepUpRequired where approval == nil {
            // Asked for before anything was sent: the rows are as they were until the step-up's run.
            rows = before
            settled = wasSettled
            do {
                let approval = try await session.mera.stepUp()
                await apply(approval: approval, keys: keys)
            } catch where isUserCancellation(error) {
                failure = tr("Nothing was cancelled.")
                busy = false
            } catch {
                failure = describe(error)
                busy = false
            }
        } catch {
            // Nothing was sent.
            rows = before
            settled = wasSettled
            failure = describe(error)
            busy = false
        }
    }
}

/// Cancels a resting order over the trading connection (p4 spec A.4.2), when one-click is live for the account at the tap
/// and Perpl's live list names the chain's order by its smart contract order id. Its row says, as it happens, what Perpl
/// did with the cancel: cancelling, then cancelled once it has left Perpl's live list — or still live (Perpl refused it),
/// filled or expired first, already gone, or not confirmed in time. Nothing reads as cancelled before Perpl's list shows
/// it. Once the cancel is out the sheet can be closed: PerplTrading finishes the wait, and records a confirmed cancel.
struct CancelOrderSheet: View {
    let market: PerpMarket
    /// The order as the chain lists it: its words.
    let order: PerpOrder
    /// The stream's order the tap matched (by `scid`), the request it belonged to then, and the account: fixed at the tap.
    let target: PerplOpenOrder
    let tapRq: Int?
    let account: PerplTrading.ActionAccount
    let onDone: () -> Void

    @Environment(PerplTrading.self) private var perplTrading
    @Environment(AppSettings.self) private var settings
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var apiPhase: APIPhase = .review
    /// The one line under a not-sent failure, or under a refusal at the gateway (nil: refused on the device).
    @State private var failureLine: String?
    /// The acks are in: the sheet can be closed while Perpl's list confirms the cancel.
    @State private var sent = false
    /// The wait for Perpl's list is over.
    @State private var settled = false
    @State private var announced: String?
    #if DEBUG && targetEnvironment(simulator)
    @Environment(\.perpsDemoAutoConfirm) private var demoAutoConfirm
    #endif

    enum APIPhase: Equatable {
        case review, authorizing, cancelling
        case result(PerplCancelResult)
        case failed(String)
        var isFailed: Bool { if case .failed = self { return true }; return false }
    }

    /// "Buy 0.001 at 78,000": the same words as the wallet's cancel sheet.
    private var what: String {
        let size = NumberStyle.number(order.size)
        let price = NumberStyle.number(order.price)
        return order.side == .buy ? tr("Buy \(size) at \(price)") : tr("Sell \(size) at \(price)")
    }

    private var result: PerplCancelResult? { if case .result(let result) = apiPhase { return result }; return nil }

    /// Try Again only after the wait, only when the cancel was refused or not confirmed, and only while Perpl's live list
    /// still has the order — never one that left it. Not after the gateway refused it (`failureLine`): the trading route
    /// rests on this socket, and the reopened sheet sends it from the wallet.
    private var canRetry: Bool {
        guard settled, failureLine == nil, perplTrading.ordersAreLive, perplTrading.openOrders.contains(where: { $0.id == target.id }) else { return false }
        switch result {
        case .refused?, .notConfirmed?: return true
        default: return false
        }
    }

    /// What the cancel's result says, as a whole sentence.
    private var line: TriggerSheetLine? {
        switch result {
        case .cancelled?: return TriggerSheetLine(text: PerpActionCopy.orderWasCancelled, tone: .success)
        case .refused(let why)?:
            // Perpl's generic "couldn't cancel it" would say it twice.
            let text = why == PerplOrderReason(status: 7, reason: 45).message ? PerpActionCopy.orderCouldntCancelGeneric : PerpActionCopy.orderCouldntCancel(why)
            return TriggerSheetLine(text: text, tone: .failure)
        case .firedFirst?: return TriggerSheetLine(text: PerpActionCopy.orderFilledBeforeCancel, tone: .warning)
        case .expiredFirst?: return TriggerSheetLine(text: PerpActionCopy.orderHadExpired, tone: .neutral)
        case .alreadyGone?: return TriggerSheetLine(text: PerpActionCopy.orderWasAlreadyGone, tone: .neutral)
        case .notConfirmed?: return settled ? TriggerSheetLine(text: PerpActionCopy.orderCancelNotConfirmed, tone: .warning) : nil
        case nil: return nil
        }
    }

    /// The result, felt: cancelled a success, still live an error, anything else a warning.
    private var feedback: SensoryFeedback? {
        switch result {
        case .cancelled?: return .success
        case .refused?: return .error
        case .firedFirst?, .expiredFirst?, .alreadyGone?: return .warning
        case .notConfirmed?: return settled ? .warning : nil
        case nil: return nil
        }
    }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow(Text(verbatim: tr(LocalizedStringResource("orderReview.market", defaultValue: "Market", comment: "A review row: the Perps market the order is on, next to its name (BTC-PERP) [tight]"))), Text(verbatim: order.symbol))
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Order").foregroundStyle(.secondary)
                            Text(verbatim: what).monospacedDigit()
                        }
                        .opacity(apiPhase == .cancelling ? 0.5 : 1)
                        Spacer(minLength: 8)
                        rowState.font(.footnote.weight(.semibold)).multilineTextAlignment(.trailing)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                } footer: {
                    Paragraph("Signed and forwarded by your Perpl API key over the trading connection.")
                }
                if session.isPasskeyAccount, apiPhase == .review || apiPhase.isFailed || canRetry {
                    Section { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.cancelOrder.summary)) }
                }
                if let line {
                    Section {
                        Label { Paragraph(verbatim: line.text) } icon: {
                            Image(systemName: PerpOutcomeTone.symbol(line.tone)).foregroundStyle(PerpOutcomeTone.color(line.tone))
                        }
                        .modifier(ParagraphLabel())
                        .font(.footnote)
                        // A refusal at the gateway: nothing was forwarded, and the reopened sheet says how it will be sent.
                        if let failureLine, case .refused? = result { Paragraph(verbatim: failureLine).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if canRetry {
                    Section {
                        Button("Try Again") { confirm() }.buttonStyle(.bordered)
                    }
                    .listRowBackground(Color.clear)
                }
                if case .failed(let message) = apiPhase {
                    Section {
                        InlineError(message: message)
                        if let failureLine { Paragraph(verbatim: failureLine).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Cancel Order"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(settled ? "Done" : "Close") { close() }.disabled(apiPhase == .authorizing || (apiPhase == .cancelling && !sent))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if apiPhase == .review || apiPhase.isFailed || apiPhase == .authorizing {
                    if !session.canSign {
                        Paragraph(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding().frame(maxWidth: .infinity).background(.bar)
                    } else {
                        PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : "Cancel Order", isBusy: apiPhase == .authorizing,
                                      foreground: .onStatus) {
                            confirm()
                        }
                        .tint(.negative)
                        .padding().frame(maxWidth: .infinity).background(.bar)
                    }
                }
            }
            .interactiveDismissDisabled(apiPhase == .authorizing || (apiPhase == .cancelling && !sent))
            // A cancel Perpl's list confirms flips its row at once, before the wait ends (the sending socket's list only, I9).
            .onChange(of: perplTrading.openOrders) { _, _ in
                guard apiPhase == .cancelling, let confirmed = perplTrading.cancelLiveResult(target.id) else { return }
                withAnimation { apiPhase = .result(confirmed) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(trigger: line?.text) { _, _ in feedback }
        .onChange(of: line?.text) { _, text in
            guard let text, text != announced else { return }
            announced = text
            AccessibilityNotification.Announcement(text).post()
        }
        #if DEBUG && targetEnvironment(simulator)
        // The scripted Perps demo only (`PerpsDemo`): with Run, this sheet's own confirm 2 s after it appears (App Lock
        // still asks).
        .task {
            guard perplTrading.isDemo, let demoAutoConfirm else { return }
            try? await Task.sleep(for: demoAutoConfirm)
            confirm()
        }
        #endif
    }

    /// The row's state, in words, with an icon that says the same (each agreeing with "order").
    @ViewBuilder private var rowState: some View {
        switch apiPhase {
        case .review, .authorizing, .failed:
            EmptyView()
        case .cancelling:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(verbatim: PerpTriggerCopy.rowCancelling)
            }
            .foregroundStyle(.secondary)
        case .result(let result):
            switch result {
            case .cancelled:
                Label { Text(verbatim: PerpActionCopy.orderCancelled) } icon: { Image(systemName: "checkmark.circle.fill") }.foregroundStyle(Color.positive)
            case .refused:
                Label { Text(verbatim: PerpActionCopy.orderStillLive) } icon: { Image(systemName: "exclamationmark.triangle.fill") }.foregroundStyle(Color.negative)
            case .firedFirst:
                Label { Text(verbatim: PerpActionCopy.orderFilledFirst) } icon: { Image(systemName: "bolt.fill") }.foregroundStyle(Color.attention)
            case .expiredFirst:
                Text(verbatim: PerpActionCopy.orderExpiredFirst).foregroundStyle(.secondary)
            case .alreadyGone:
                Text(verbatim: PerpActionCopy.orderAlreadyGone).foregroundStyle(.secondary)
            case .notConfirmed:
                if settled {
                    Label { Text(verbatim: PerpActionCopy.orderNotConfirmed) } icon: { Image(systemName: "questionmark.circle") }.foregroundStyle(Color.attention)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(verbatim: PerpTriggerCopy.rowCancelling)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func close() {
        dismiss()
        if sent { onDone() }
    }

    /// The confirm (A.3.1), Try Again included: ignored unless nothing is under way, and busy at once, before the App Lock
    /// prompt — a double tap can never send a second cancel.
    private func confirm() {
        guard apiPhase == .review || apiPhase.isFailed || canRetry else { return }
        apiPhase = .authorizing
        failureLine = nil
        settled = false
        Task { await cancel() }
    }

    /// App Lock as the wallet's cancel sheet asks it (it fails closed without a device passcode), then a passkey account's
    /// step-up — every run asks again (MERA-PLAN §3) — then PerplTrading sends the cancel and follows it to Perpl's list.
    private func cancel(approval: MeraSession.StepUp? = nil) async {
        if approval == nil, settings.appLockApplies(to: session.account) {
            guard BiometricGate.canAuthenticateOwner else {
                apiPhase = .failed(tr("App Lock needs a device passcode. Set one in iOS Settings, then try again."))
                return
            }
            // The wallet's cancel sheet's own prompt: "Confirm Cancel Order".
            let action = tr("Cancel Order")
            guard await BiometricGate.authenticate(reason: "Confirm \(action)") else { apiPhase = .review; return }
        }
        apiPhase = .cancelling
        do {
            let outcome = try await perplTrading.cancelResting(target, tapRq: tapRq, chainOrder: PerplTrading.ChainOrderKey(order), account: account,
                                                               title: tr("Cancelled \(order.symbol) order"), subtitle: what, approval: approval) { acks in
                // The cancel is out: the sheet can be closed while Perpl's list confirms it.
                sent = true
                if let decided = acks[target.id] {
                    // The gateway refused it: nothing was forwarded (the route already rests on this socket: the wallet's line).
                    if decided != .notConfirmed { failureLine = perplTrading.nothingSentLine(for: account) }
                    withAnimation { apiPhase = .result(decided) }
                }
                // Perpl's list may have confirmed it already, before its ack was in.
                if let confirmed = perplTrading.cancelLiveResult(target.id) { withAnimation { apiPhase = .result(confirmed) } }
            }
            sent = true
            // Perpl refused it because one-click is off on Perpl (OrderForwardingNotAllowed): no Try Again on this route, the
            // reopened sheet sends it from the wallet.
            if case .refused = outcome, perplTrading.cancelRefusedForForwarding(target.id) { failureLine = perplTrading.nothingSentLine(for: account) }
            withAnimation { apiPhase = .result(outcome) }
            settled = true
        } catch is MeraSession.StepUpRequired where approval == nil {
            do {
                let approval = try await session.mera.stepUp()
                await cancel(approval: approval)
            } catch where isUserCancellation(error) {
                failureLine = perplTrading.nothingSentLine(for: account)
                apiPhase = .failed(tr("Nothing was cancelled."))
            } catch {
                failureLine = perplTrading.nothingSentLine(for: account)
                apiPhase = .failed(describe(error))
            }
        } catch {
            // Nothing was sent. Refused on the device, or Perpl's list isn't there yet to check the order against: the message
            // says why and what to do, and nothing else needs saying.
            let onDevice = (error as? PerplTradeError)?.isInvalidOrder == true || error is PerplTrading.OrdersNotChecked
            failureLine = onDevice ? nil : perplTrading.nothingSentLine(for: account)
            apiPhase = .failed(describe(error))
        }
    }
}

/// One TP/SL of the cancel sheet: its kind, its price and size, and what Perpl's list showed of its cancel. It stays in
/// place whatever happens to it, so nothing moves under a finger (I30).
private struct CancelTriggerRow: View {
    let order: PerplOpenOrder
    let market: PerpMarket
    let state: CancelTriggersSheet.RowState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(order.isStopLoss ? "Stop loss" : "Take profit").foregroundStyle(.secondary)
                Text(verbatim: PerpTriggerCopy.priceAndSize(order, market: market))
                    .monospacedDigit()
                    .foregroundStyle(order.isStopLoss ? Color.negative : Color.positive)
            }
            .opacity(state == .cancelling ? 0.5 : 1)
            Spacer(minLength: 8)
            status
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    /// The row's state, in words, with an icon that says the same.
    @ViewBuilder private var status: some View {
        switch state {
        case .ready:
            EmptyView()
        case .cancelling:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(verbatim: PerpTriggerCopy.rowCancelling)
            }
            .foregroundStyle(.secondary)
        case .cancelled:
            Label { Text(verbatim: PerpTriggerCopy.rowCancelled) } icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(Color.positive)
        case .stillLive:
            Label { Text(verbatim: PerpTriggerCopy.rowStillLive) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .foregroundStyle(Color.negative)
        case .alreadyGone:
            Text(verbatim: PerpTriggerCopy.rowAlreadyGone).foregroundStyle(.secondary)
        case .firedFirst:
            Label { Text(verbatim: PerpTriggerCopy.rowFiredFirst) } icon: { Image(systemName: "bolt.fill") }
                .foregroundStyle(Color.attention)
        case .expiredFirst:
            Text(verbatim: PerpTriggerCopy.rowExpiredFirst).foregroundStyle(.secondary)
        case .notConfirmed:
            Label { Text(verbatim: PerpTriggerCopy.rowNotConfirmed) } icon: { Image(systemName: "questionmark.circle") }
                .foregroundStyle(Color.attention)
        }
    }
}

/// Where a TP/SL sheet is: editing, sending, done with a line per step, or failed before anything was sent.
enum TriggerSheetPhase: Equatable {
    case editing, working
    case finished([TriggerSheetLine])
    case failed(String)
}

/// One sentence of a TP/SL sheet's outcome, with the tone its icon and colour show.
struct TriggerSheetLine: Equatable, Hashable {
    let text: String
    let tone: PerplOrderOutcome.Tone

    init(text: String, tone: PerplOrderOutcome.Tone) {
        self.text = text
        self.tone = tone
    }

    /// A step's line: done as asked, or a warning.
    init(text: String, warning: Bool) {
        self.init(text: text, tone: warning ? .warning : .success)
    }
}

/// The outcome block both TP/SL sheets end with. Every line wraps as a paragraph (in Korean, between words: I28), and
/// its icon and colour say what its words say.
struct TriggerSheetOutcomeSection: View {
    let phase: TriggerSheetPhase

    var body: some View {
        switch phase {
        case .finished(let lines):
            Section {
                ForEach(lines, id: \.self) { line in
                    Label { Paragraph(verbatim: line.text) } icon: {
                        Image(systemName: PerpOutcomeTone.symbol(line.tone)).foregroundStyle(PerpOutcomeTone.color(line.tone))
                    }
                    .modifier(ParagraphLabel())
                    .font(.footnote)
                }
            }
        case .failed(let message):
            Section { InlineError(message: message) }.listRowBackground(Color.clear)
        case .editing, .working:
            EmptyView()
        }
    }
}

/// The TP/SL sheets' words about cancels and changes Perpl confirms on its live list, in the app's language: each a whole
/// sentence (or a short state) with its own key, a take-profit's and a stop-loss's written apart. A trigger is named by
/// its price and its size with the asset: "75,000 (0.00092 BTC)".
enum PerpTriggerCopy {
    static func price(_ order: PerplOpenOrder, market: PerpMarket) -> String {
        NumberStyle.number(Double(order.triggerPriceRaw ?? 0) / pow(10, Double(market.priceDecimals)))
    }

    /// The size it closes with the asset, "0.00092 BTC".
    static func size(_ order: PerplOpenOrder, market: PerpMarket) -> String {
        "\(NumberStyle.number(Double(order.sizeRaw) / pow(10, Double(market.lotDecimals)))) \(market.asset)"
    }

    /// A row's value, "75,000 (0.00092 BTC)": nothing to translate (I43).
    static func priceAndSize(_ order: PerplOpenOrder, market: PerpMarket) -> String {
        "\(price(order, market: market)) (\(size(order, market: market)))"
    }

    // MARK: A row's state [tight]

    static var rowCancelling: String {
        tr(LocalizedStringResource("cancelRow.cancelling", defaultValue: "Cancelling…", comment: "[tight] A take-profit / stop-loss row's state while its cancel is on its way to Perpl: in the TP/SL cancel sheet, and on the Orders tab's TP/SL card in place of its Cancel button."))
    }

    static var rowCancelled: String {
        tr(LocalizedStringResource("cancelRow.cancelled", defaultValue: "Cancelled", comment: "[tight] A take-profit / stop-loss row's state in the TP/SL cancel sheet: Perpl's live list confirms it was cancelled (an adjective)."))
    }

    static var rowStillLive: String {
        tr(LocalizedStringResource("cancelRow.stillLive", defaultValue: "Still live", comment: "[tight] A take-profit / stop-loss row's state in the TP/SL cancel sheet: Perpl refused the cancel, so the order is still active."))
    }

    static var rowAlreadyGone: String {
        tr(LocalizedStringResource("cancelRow.alreadyGone", defaultValue: "Already gone", comment: "[tight] A take-profit / stop-loss row's state in the TP/SL cancel sheet: the order was no longer on Perpl when the cancel arrived, so there was nothing to cancel."))
    }

    static var rowFiredFirst: String {
        tr(LocalizedStringResource("cancelRow.firedFirst", defaultValue: "Triggered first", comment: "[tight] A take-profit / stop-loss row's state in the TP/SL cancel sheet: it triggered (Perpl started closing the position at its price) before the cancel arrived."))
    }

    static var rowExpiredFirst: String {
        tr(LocalizedStringResource("cancelRow.expiredFirst", defaultValue: "Expired first", comment: "[tight] A take-profit / stop-loss row's state in the TP/SL cancel sheet: it had expired before the cancel arrived."))
    }

    static var rowNotConfirmed: String {
        tr(LocalizedStringResource("cancelRow.notConfirmed", defaultValue: "Not confirmed", comment: "[tight] A take-profit / stop-loss row's state in the TP/SL cancel sheet: Perpl hasn't confirmed the cancel in time, so the order may still be active."))
    }

    // MARK: The cancel sheet's outcome

    /// "Cancelled 2 TP/SL.": what Perpl's list confirmed (the plural key's count).
    static func cancelled(count: Int) -> String {
        tr(LocalizedStringResource("Cancelled \(count) TP/SL.", comment: "The TP/SL cancel sheet's result: Perpl's live list confirms this many take-profit / stop-loss orders were cancelled. The value: their count."))
    }

    /// The Perps screen's note while cancels are on their way for TP/SL left with no position (I32).
    static func cancellingLeftovers(count: Int, asset: String) -> String {
        tr(LocalizedStringResource("Cancelling \(count) TP/SL on \(asset)…", comment: "The Perps screen's note while cancels are on their way to Perpl for take-profit / stop-loss orders left with no position to close. The first value: their count; the second: the market's asset (BTC)."))
    }

    /// The sentence for a row whose cancel didn't end in "cancelled", or nil.
    static func line(for order: PerplOpenOrder, state: CancelTriggersSheet.RowState, market: PerpMarket) -> TriggerSheetLine? {
        let price = Self.price(order, market: market), size = Self.size(order, market: market)
        let sl = order.isStopLoss
        switch state {
        case .ready, .cancelling, .cancelled:
            return nil
        case .stillLive(let why):
            return TriggerSheetLine(text: sl
                ? tr(LocalizedStringResource("Couldn't cancel the stop-loss at \(price) (\(size)): \(why) It is still live.", comment: "The TP/SL cancel sheet: Perpl refused to cancel a stop-loss, which stays active. The first value: its trigger price; the second: the size it closes with the asset (0.001 BTC); the third: Perpl's reason, one or two whole sentences."))
                : tr(LocalizedStringResource("Couldn't cancel the take-profit at \(price) (\(size)): \(why) It is still live.", comment: "The TP/SL cancel sheet: Perpl refused to cancel a take-profit, which stays active. The first value: its trigger price; the second: the size it closes with the asset (0.001 BTC); the third: Perpl's reason, one or two whole sentences.")),
                tone: .failure)
        case .alreadyGone:
            return TriggerSheetLine(text: sl
                ? tr(LocalizedStringResource("The stop-loss at \(price) (\(size)) was already gone.", comment: "The TP/SL cancel sheet: the stop-loss was no longer on Perpl when the cancel arrived, so there was nothing to cancel. The first value: its trigger price; the second: the size it closed with the asset (0.001 BTC)."))
                : tr(LocalizedStringResource("The take-profit at \(price) (\(size)) was already gone.", comment: "The TP/SL cancel sheet: the take-profit was no longer on Perpl when the cancel arrived, so there was nothing to cancel. The first value: its trigger price; the second: the size it closed with the asset (0.001 BTC).")),
                tone: .neutral)
        case .firedFirst:
            return TriggerSheetLine(text: sl
                ? tr(LocalizedStringResource("The stop-loss at \(price) (\(size)) triggered before the cancel landed.", comment: "The TP/SL cancel sheet: the stop-loss triggered (Perpl started closing the position at its price) before Perpl processed the cancel. The first value: its trigger price; the second: the size it closes with the asset (0.001 BTC)."))
                : tr(LocalizedStringResource("The take-profit at \(price) (\(size)) triggered before the cancel landed.", comment: "The TP/SL cancel sheet: the take-profit triggered (Perpl started closing the position at its price) before Perpl processed the cancel. The first value: its trigger price; the second: the size it closes with the asset (0.001 BTC).")),
                tone: .warning)
        case .expiredFirst:
            return TriggerSheetLine(text: sl
                ? tr(LocalizedStringResource("The stop-loss at \(price) (\(size)) had already expired.", comment: "The TP/SL cancel sheet: the stop-loss had expired before Perpl processed the cancel. The first value: its trigger price; the second: the size it closed with the asset (0.001 BTC)."))
                : tr(LocalizedStringResource("The take-profit at \(price) (\(size)) had already expired.", comment: "The TP/SL cancel sheet: the take-profit had expired before Perpl processed the cancel. The first value: its trigger price; the second: the size it closed with the asset (0.001 BTC).")),
                tone: .neutral)
        case .notConfirmed:
            return TriggerSheetLine(text: sl
                ? tr(LocalizedStringResource("Not confirmed yet: Perpl hasn't removed the stop-loss at \(price) (\(size)). Check Orders: it may still be live.", comment: "The TP/SL cancel sheet: the cancel was sent but Perpl's live list didn't confirm it in time, so the stop-loss may still be active. Orders is a tab of the Perps screen. The first value: its trigger price; the second: the size it closes with the asset (0.001 BTC)."))
                : tr(LocalizedStringResource("Not confirmed yet: Perpl hasn't removed the take-profit at \(price) (\(size)). Check Orders: it may still be live.", comment: "The TP/SL cancel sheet: the cancel was sent but Perpl's live list didn't confirm it in time, so the take-profit may still be active. Orders is a tab of the Perps screen. The first value: its trigger price; the second: the size it closes with the asset (0.001 BTC).")),
                tone: .warning)
        }
    }

    // MARK: Moving a position's TP/SL

    /// What a kind is doing while the change runs (I42).
    static func step(_ kind: PerplTriggerKind, _ step: PerplTrading.TriggerChangeStep) -> String {
        switch (kind, step) {
        case (.takeProfit, .cancelling):
            return tr(LocalizedStringResource("Cancelling the old take-profit…", comment: "The position's TP/SL sheet, while it works: the cancel of the take-profit being replaced or removed is on its way to Perpl."))
        case (.stopLoss, .cancelling):
            return tr(LocalizedStringResource("Cancelling the old stop-loss…", comment: "The position's TP/SL sheet, while it works: the cancel of the stop-loss being replaced or removed is on its way to Perpl."))
        case (.takeProfit, .placing):
            return tr(LocalizedStringResource("Placing the new take-profit…", comment: "The position's TP/SL sheet, while it works: the new take-profit is being sent to Perpl and its answer awaited."))
        case (.stopLoss, .placing):
            return tr(LocalizedStringResource("Placing the new stop-loss…", comment: "The position's TP/SL sheet, while it works: the new stop-loss is being sent to Perpl and its answer awaited."))
        }
    }

    /// Perpl admitted the new trigger but its list didn't show it in time: it may be live (I21).
    static func notListed(_ kind: PerplTriggerKind, replacing: Bool) -> String {
        switch (kind, replacing) {
        case (.takeProfit, false):
            return tr(LocalizedStringResource("Perpl accepted the new take-profit but hasn't listed it yet. Check Orders before placing it again.", comment: "The position's TP/SL sheet: Perpl took the new take-profit, but its live list didn't show it in time, so it may or may not be active. Orders is a tab of the Perps screen."))
        case (.stopLoss, false):
            return tr(LocalizedStringResource("Perpl accepted the new stop-loss but hasn't listed it yet. Check Orders before placing it again.", comment: "The position's TP/SL sheet: Perpl took the new stop-loss, but its live list didn't show it in time, so it may or may not be active. Orders is a tab of the Perps screen."))
        case (.takeProfit, true):
            return tr(LocalizedStringResource("Perpl accepted the new take-profit but hasn't listed it yet. The old one was cancelled. Check Orders before placing it again.", comment: "The position's TP/SL sheet: the old take-profit was cancelled; Perpl took the new one, but its live list didn't show it in time, so it may or may not be active. Orders is a tab of the Perps screen."))
        case (.stopLoss, true):
            return tr(LocalizedStringResource("Perpl accepted the new stop-loss but hasn't listed it yet. The old one was cancelled. Check Orders before placing it again.", comment: "The position's TP/SL sheet: the old stop-loss was cancelled; Perpl took the new one, but its live list didn't show it in time, so it may or may not be active. Orders is a tab of the Perps screen."))
        }
    }

    /// The new trigger fired as soon as Perpl armed it.
    static func triggeredAtOnce(_ kind: PerplTriggerKind, price: String) -> String {
        kind == .takeProfit
            ? tr(LocalizedStringResource("The new take-profit at \(price) triggered at once.", comment: "The position's TP/SL sheet: the new take-profit fired as soon as Perpl armed it, so Perpl is closing the position at its price. The value: its trigger price."))
            : tr(LocalizedStringResource("The new stop-loss at \(price) triggered at once.", comment: "The position's TP/SL sheet: the new stop-loss fired as soon as Perpl armed it, so Perpl is closing the position at its price. The value: its trigger price."))
    }
}
