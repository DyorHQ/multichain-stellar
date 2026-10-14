import DyorKit
import SwiftUI

/// One line under an order's result: a take-profit's or stop-loss's state, a trigger warning, or a provisional
/// failure. `tone` nil: still being checked (a spinner, not an icon).
struct PerpOrderOutcomeLine: Hashable {
    let text: String
    let tone: PerplOrderOutcome.Tone?
}

/// The icon and colour a result's tone is shown with. Words always come with them: the colour never says it alone.
enum PerpOutcomeTone {
    static func symbol(_ tone: PerplOrderOutcome.Tone) -> String {
        switch tone {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .neutral: return "minus.circle"
        }
    }

    static func color(_ tone: PerplOrderOutcome.Tone) -> Color {
        switch tone {
        case .success: return .positive
        case .warning: return .attention
        case .failure: return .negative
        case .neutral: return .secondary
        }
    }

    /// The haptic a result is felt with: success, a warning, or an error; a neutral one (a cancel made elsewhere) is none.
    static func feedback(_ tone: PerplOrderOutcome.Tone) -> SensoryFeedback? {
        switch tone {
        case .success: return .success
        case .warning: return .warning
        case .failure: return .error
        case .neutral: return nil
        }
    }
}

/// An order's result in its sheet's list: the headline and the detail under it, then its lines (the take-profit and
/// stop-loss, a warning), a "View" link to the transaction Perpl filled it in, and an optional action under them. Every
/// line wraps as a paragraph (in Korean, between words).
struct PerpOrderOutcomeSection<Accessory: View>: View {
    let text: PerplOutcomeText?
    var lines: [PerpOrderOutcomeLine] = []
    var link: URL?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Section {
            if let text {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Paragraph(verbatim: text.headline).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if let detail = text.detail {
                            Paragraph(verbatim: detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: PerpOutcomeTone.symbol(text.tone)).foregroundStyle(PerpOutcomeTone.color(text.tone))
                }
                .modifier(ParagraphLabel())
                .accessibilityElement(children: .combine)
            }
            ForEach(lines, id: \.self) { line in
                Label {
                    Paragraph(verbatim: line.text).font(.footnote)
                } icon: {
                    if let tone = line.tone {
                        Image(systemName: PerpOutcomeTone.symbol(tone)).foregroundStyle(PerpOutcomeTone.color(tone))
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .modifier(ParagraphLabel())
                .font(.footnote)
            }
            if let link {
                Link(destination: link) { Text("View", comment: "Opens the transaction in a block explorer: a verb [tight]") }
                    .font(.footnote.weight(.semibold))
            }
            accessory()
        }
    }
}

extension PerpOrderOutcomeSection where Accessory == EmptyView {
    init(text: PerplOutcomeText?, lines: [PerpOrderOutcomeLine] = [], link: URL? = nil) {
        self.init(text: text, lines: lines, link: link) { EmptyView() }
    }
}

/// An order's result in a sheet's bottom bar, where the order button was: so it shows at the sheet's medium height. The
/// headline wraps whole, as many lines as it needs: a line limit would turn the paragraph back into plain text (Korean
/// would break inside words) and could cut off what to check.
struct PerpOrderStatusBar: View {
    let text: PerplOutcomeText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: PerpOutcomeTone.symbol(text.tone)).foregroundStyle(PerpOutcomeTone.color(text.tone))
            Paragraph(verbatim: text.headline).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The bottom bar of a sheet whose transaction confirmed while what it did is read from its receipt: "Reading the
/// result…" (Done held for the first `doneHold`, so the result usually shows before the sheet can close), then the result
/// where the button was, with Done.
struct ReceiptResultBar: View {
    /// The result, once read; nil while it is read (or when there was nothing to say).
    let settled: PerplOutcomeText?
    /// The receipt is being read now.
    let reading: Bool
    let holdingDone: Bool
    let onDone: () -> Void

    /// How long Done waits for the result before it is offered anyway.
    static let doneHold: Duration = .seconds(2)

    var body: some View {
        VStack(spacing: 8) {
            if let settled {
                PerpOrderStatusBar(text: settled)
            } else if reading {
                HStack(spacing: 10) {
                    ProgressView()
                    Paragraph(verbatim: PerpOrderCopy.reading).font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if settled != nil || !holdingDone {
                PrimaryButton(title: "Done", systemImage: "checkmark") { onDone() }
            }
        }
    }
}

/// The trade screen's row for an order sent from it whose sheet is closed: still waiting, or its result until it is
/// seen (a success leaves by itself; a warning, a failure, or a success whose take-profit or stop-loss isn't known to be
/// live stays until dismissed). Laid out like the protection notice.
struct PerpOrderStatusRow: View {
    let order: PerplTrackedOrder
    let onDismiss: () -> Void

    private var tone: PerplOrderOutcome.Tone? { order.entry?.tone }
    private var tint: Color {
        // A position whose take-profit or stop-loss isn't known to be live is never shown as a plain success.
        if order.hasTriggerWarning, tone == .success || tone == nil { return .attention }
        return tone.map(PerpOutcomeTone.color) ?? .brand
    }

    /// The detail under the headline: what to check when the result can't be read or Perpl never answered the entry
    /// (never place it again blindly, GL-1), else the result's own detail.
    private func detail(_ entry: PerplOrderOutcome, _ text: PerplOutcomeText) -> String? {
        guard PerplTracker.isUnconfirmed(entry) else { return text.detail }
        // A wallet-signed order whose receipt couldn't be read: what to check (Perpl has no report of it).
        if order.isOnChain { return PerpOnChainCopy.unreadable }
        // A close Perpl never answered: it may have gone through (GL-1), so Positions is checked before closing again.
        if !order.acknowledged, order.isClose { return PerpActionCopy.closeUnknown }
        if !order.acknowledged { return PerpOrderCopy.unknown(takeProfit: order.takeProfit != nil, stopLoss: order.stopLoss != nil) }
        return text.detail
    }

    /// The row's title: the order ("Long BTC-PERP"), or for a close sent from the position's Close sheet, the close
    /// ("Close BTC").
    private var title: String {
        if order.isClose { return PerpOnChainCopy.closeTitle(order.asset) }
        let perp = "\(order.asset)-PERP"
        return order.side == .long ? tr("Long \(perp)") : tr("Short \(perp)")
    }

    /// The result in words: a close's said of the position.
    private func words(_ entry: PerplOrderOutcome) -> PerplOutcomeText {
        order.isClose ? PerplOutcomeText.close(entry, order.textContext) : PerplOutcomeText.order(entry, order.textContext)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let tone {
                    Image(systemName: PerpOutcomeTone.symbol(tone)).foregroundStyle(PerpOutcomeTone.color(tone))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Paragraph(verbatim: title).font(.subheadline.weight(.semibold))
                if let entry = order.entry {
                    let text = words(entry)
                    Paragraph(verbatim: text.headline).font(.footnote.weight(.medium))
                    if let detail = detail(entry, text) {
                        Paragraph(verbatim: detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else if order.isOnChain {
                    Paragraph(verbatim: PerpOrderCopy.reading).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Paragraph(verbatim: order.acknowledged ? PerpOrderCopy.waiting : PerpOrderCopy.stillListening).font(.footnote).foregroundStyle(.secondary)
                    if let provisional = order.provisional {
                        Paragraph(verbatim: PerplOutcomeText.provisional(provisional)).font(.footnote).foregroundStyle(Color.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // A take-profit or stop-loss that isn't known to be live: said from the moment the order is followed,
                // whatever the entry is doing (the position may be unprotected).
                if let warning = PerpOrderCopy.triggerWarning(order) {
                    Label { Paragraph(verbatim: warning) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .modifier(ParagraphLabel())
                        .font(.footnote).foregroundStyle(Color.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The order sheet's own words about an order it sent, in the app's language, each a whole sentence with its own key.
enum PerpOrderCopy {
    static var sending: String {
        tr(LocalizedStringResource("Sending to Perpl…", comment: "The Perps order sheet's status while the order's frames go out to Perpl over the trading connection."))
    }

    /// Perpl took the order for forwarding (not "placed": nothing is on the order book yet).
    static var waiting: String {
        tr(LocalizedStringResource("Waiting for Perpl…", comment: "The Perps order sheet's status: Perpl took the order (market or limit) for forwarding and the app waits for its result. Not 'placed': nothing is known to be on the order book yet."))
    }

    /// A wallet-signed order's transaction confirmed; what it did is being read from its receipt.
    static var reading: String {
        tr(LocalizedStringResource("Reading the result…", comment: "A Perps sheet's status: the order's (or close's, or margin's) transaction confirmed on Monad and the app reads what it did from it (filled, partly filled, not filled)."))
    }

    static var stillListening: String {
        tr(LocalizedStringResource("Still listening for Perpl…", comment: "The Perps order sheet's status: Perpl hasn't answered the order yet; a late answer is still read."))
    }

    static func canClose(market: String) -> String {
        tr(LocalizedStringResource("You can close this. The result will show on the \(market) screen.", comment: "Under the Perps order sheet's waiting status. The value: the market's name (“BTC-PERP”), whose trade screen shows the order's result."))
    }

    static var stillInTicket: String {
        tr(LocalizedStringResource("Your order is still in the ticket.", comment: "Under a Perps order's result when nothing executed: the size and TP/SL typed are kept in the order ticket, ready to send again."))
    }

    /// A limit's review row with its flags (I43): what gets signed, said in full.
    static func limitType(price: String, postOnly: Bool, reduceOnly: Bool) -> String? {
        switch (postOnly, reduceOnly) {
        case (true, true): return tr(LocalizedStringResource("Post-only, reduce-only limit at \(price)", comment: "A Perps order review's Type row: a limit order that only rests on the book (post-only, maker) and can only shrink the position (reduce-only). The value: the limit price."))
        case (true, false): return tr(LocalizedStringResource("Post-only limit at \(price)", comment: "A Perps order review's Type row: a limit order that only rests on the book as a maker (post-only), never fills at once. The value: the limit price."))
        case (false, true): return tr(LocalizedStringResource("Reduce-only limit at \(price)", comment: "A Perps order review's Type row: a limit order that can only shrink the position (reduce-only). The value: the limit price."))
        case (false, false): return nil
        }
    }

    static func checking(_ kind: PerplTriggerKind) -> String {
        kind == .takeProfit
            ? tr(LocalizedStringResource("Checking the take-profit…", comment: "A Perps order sheet's line while Perpl's answer about the order's take-profit is awaited."))
            : tr(LocalizedStringResource("Checking the stop-loss…", comment: "A Perps order sheet's line while Perpl's answer about the order's stop-loss is awaited."))
    }

    static func accepted(_ kind: PerplTriggerKind, price: String) -> String {
        kind == .takeProfit
            ? tr(LocalizedStringResource("Take-profit accepted at \(price). It activates when the order fills.", comment: "A Perps order sheet's line: Perpl took the order's take-profit; it waits for the order to fill before it protects anything. The value: the trigger price."))
            : tr(LocalizedStringResource("Stop-loss accepted at \(price). It activates when the order fills.", comment: "A Perps order sheet's line: Perpl took the order's stop-loss; it waits for the order to fill before it protects anything. The value: the trigger price."))
    }

    static func triggeredAtOnce(_ kind: PerplTriggerKind, price: String) -> String {
        kind == .takeProfit
            ? tr(LocalizedStringResource("The take-profit at \(price) triggered at once.", comment: "A Perps order sheet's line: the order's take-profit fired as soon as it was active. The value: the trigger price."))
            : tr(LocalizedStringResource("The stop-loss at \(price) triggered at once.", comment: "A Perps order sheet's line: the order's stop-loss fired as soon as it was active. The value: the trigger price."))
    }

    /// The order executed nothing and Perpl cancelled its take-profit and stop-loss with it.
    static func cancelledWith(takeProfit: Bool, stopLoss: Bool) -> String? {
        switch (takeProfit, stopLoss) {
        case (true, true): return tr(LocalizedStringResource("Its take-profit and stop-loss were cancelled with it.", comment: "A Perps order sheet's line under an order that executed nothing: Perpl cancelled the order's take-profit and stop-loss too."))
        case (true, false): return tr(LocalizedStringResource("Its take-profit was cancelled with it.", comment: "A Perps order sheet's line under an order that executed nothing: Perpl cancelled the order's take-profit too."))
        case (false, true): return tr(LocalizedStringResource("Its stop-loss was cancelled with it.", comment: "A Perps order sheet's line under an order that executed nothing: Perpl cancelled the order's stop-loss too."))
        case (false, false): return nil
        }
    }

    /// The order executed nothing, but Perpl still has its take-profit / stop-loss armed (they would act on a later
    /// position).
    static func stillArmed(takeProfit: Bool, stopLoss: Bool) -> String? {
        switch (takeProfit, stopLoss) {
        case (true, true): return tr(LocalizedStringResource("Its take-profit and stop-loss are still armed with no position to close. Cancel them so they can't act on a later position.", comment: "A Perps order sheet's warning under an order that executed nothing: Perpl still has its take-profit and stop-loss armed. A Cancel button follows."))
        case (true, false): return tr(LocalizedStringResource("Its take-profit is still armed with no position to close. Cancel it so it can't act on a later position.", comment: "A Perps order sheet's warning under an order that executed nothing: Perpl still has its take-profit armed. A Cancel button follows."))
        case (false, true): return tr(LocalizedStringResource("Its stop-loss is still armed with no position to close. Cancel it so it can't act on a later position.", comment: "A Perps order sheet's warning under an order that executed nothing: Perpl still has its stop-loss armed. A Cancel button follows."))
        case (false, false): return nil
        }
    }

    static func notListed(_ kind: PerplTriggerKind) -> String {
        kind == .takeProfit
            ? tr(LocalizedStringResource("Perpl hasn't listed the take-profit yet. Check Orders before placing it again.", comment: "A Perps order sheet's warning: Perpl took the order's take-profit but its answer didn't arrive in time. Orders is a tab of the Perps screen."))
            : tr(LocalizedStringResource("Perpl hasn't listed the stop-loss yet. Check Orders before placing it again.", comment: "A Perps order sheet's warning: Perpl took the order's stop-loss but its answer didn't arrive in time. Orders is a tab of the Perps screen."))
    }

    /// Perpl never answered the entry: it may have been placed, and its triggers were not sent (GL-1). Never place it
    /// again blindly. `takeProfit` / `stopLoss`: they were asked for.
    static func unknown(takeProfit: Bool, stopLoss: Bool) -> String {
        var message = tr("Order status unknown — Perpl didn't confirm this order, so it may have been placed. Check Open Orders and Positions before placing it again.")
        if let notSent = notSent(takeProfit: takeProfit, stopLoss: stopLoss) { message = WordWrap.sentences(message, notSent) }
        return message
    }

    /// The take-profit / stop-loss of an entry Perpl never answered: they never left the device.
    static func notSent(takeProfit: Bool, stopLoss: Bool) -> String? {
        switch (takeProfit, stopLoss) {
        case (true, true): return tr("Its take-profit and stop-loss were not sent: if the order is open, set them with TP/SL on the position.")
        case (true, false): return tr("Its take-profit was not sent: if the order is open, set it with TP/SL on the position.")
        case (false, true): return tr("Its stop-loss was not sent: if the order is open, set it with TP/SL on the position.")
        case (false, false): return nil
        }
    }

    /// Perpl refused the take-profit / stop-loss while the entry's result isn't in yet (nothing is known to be open).
    static func refusedUndecided(takeProfit: Bool, stopLoss: Bool) -> String? {
        switch (takeProfit, stopLoss) {
        case (true, true): return tr(LocalizedStringResource("Perpl didn't accept the take-profit and stop-loss. If the order fills, set them with TP/SL on the position.", comment: "A Perps order sheet's and trade screen's warning while the order's result isn't in yet: Perpl refused its take-profit and stop-loss. TP/SL is the position's button for setting them."))
        case (true, false): return tr(LocalizedStringResource("Perpl didn't accept the take-profit. If the order fills, set it with TP/SL on the position.", comment: "A Perps order sheet's and trade screen's warning while the order's result isn't in yet: Perpl refused its take-profit. TP/SL is the position's button for setting it."))
        case (false, true): return tr(LocalizedStringResource("Perpl didn't accept the stop-loss. If the order fills, set it with TP/SL on the position.", comment: "A Perps order sheet's and trade screen's warning while the order's result isn't in yet: Perpl refused its stop-loss. TP/SL is the position's button for setting it."))
        case (false, false): return nil
        }
    }

    /// The order executed nothing; no live list could say yet whether Perpl cancelled its armed take-profit / stop-loss
    /// with it. A Cancel button follows when the live list shows them.
    static func mayStillBeArmed(takeProfit: Bool, stopLoss: Bool) -> String? {
        switch (takeProfit, stopLoss) {
        case (true, true): return tr(LocalizedStringResource("Check Orders: its take-profit and stop-loss may still be armed.", comment: "A Perps order sheet's warning under an order that executed nothing: it isn't confirmed that Perpl cancelled the order's take-profit and stop-loss with it, so they may still be active and act on a later position. Orders is a tab of the Perps screen."))
        case (true, false): return tr(LocalizedStringResource("Check Orders: its take-profit may still be armed.", comment: "A Perps order sheet's warning under an order that executed nothing: it isn't confirmed that Perpl cancelled the order's take-profit with it, so it may still be active and act on a later position. Orders is a tab of the Perps screen."))
        case (false, true): return tr(LocalizedStringResource("Check Orders: its stop-loss may still be armed.", comment: "A Perps order sheet's warning under an order that executed nothing: it isn't confirmed that Perpl cancelled the order's stop-loss with it, so it may still be active and act on a later position. Orders is a tab of the Perps screen."))
        case (false, false): return nil
        }
    }

    /// The order's take-profit / stop-loss was cancelled after it had been placed (from Orders, by Perpl after the other
    /// one fired, or elsewhere): said without a cause the app doesn't know.
    static func cancelledLater(_ kind: PerplTriggerKind) -> String {
        kind == .takeProfit
            ? tr(LocalizedStringResource("Take-profit cancelled.", comment: "A Perps order sheet's line: the order's take-profit was cancelled some time after it was placed (from Orders, or by Perpl after the stop-loss fired)."))
            : tr(LocalizedStringResource("Stop-loss cancelled.", comment: "A Perps order sheet's line: the order's stop-loss was cancelled some time after it was placed (from Orders, or by Perpl after the take-profit fired). The position may no longer be protected by it."))
    }

    /// The order's take-profit / stop-loss fired some time after it was placed (the security audit's GT-9 words).
    static func triggeredLater(_ kind: PerplTriggerKind) -> String {
        kind == .takeProfit ? tr("Take-profit triggered") : tr("Stop-loss triggered")
    }

    /// The warning about the take-profit / stop-loss asked for with the order that aren't known to be live — never sent
    /// (Perpl never answered the entry), refused, or never answered — from the moment the order is followed, by what the
    /// entry is doing now: its result not in yet, a position opened, resting on the book, or nothing executed (a refusal
    /// then needs no word). The sheet and the trade screen's status row both say it. Nil: nothing to warn about.
    static func triggerWarning(_ order: PerplTrackedOrder) -> String? {
        let entry = order.entry
        let executedNothing = entry?.executedNothing == true
        let filled = entry?.fill != nil || entry.map(PerplTracker.isObserved) == true
        let resting = entry.map(PerplTracker.isResting) ?? false
        let tp = order.takeProfit, sl = order.stopLoss
        var parts: [String] = []
        // Never sent: an unanswered entry that is "not confirmed" already says so in its own detail (`unknown`).
        let unansweredUnconfirmed = !order.acknowledged && entry.map(PerplTracker.isUnconfirmed) == true
        if !executedNothing, !unansweredUnconfirmed, let text = notSent(takeProfit: tp?.notSent == true, stopLoss: sl?.notSent == true) {
            parts.append(text)
        }
        let refusedTP = tp?.refused == true, refusedSL = sl?.refused == true
        if !executedNothing, refusedTP || refusedSL {
            if filled {
                switch (refusedTP, refusedSL) {
                case (true, true): parts.append(tr("Position opened, but Perpl didn't accept the take-profit and stop-loss. Set them with TP/SL on the position."))
                case (true, false): parts.append(tr("Position opened, but Perpl didn't accept the take-profit. Set it with TP/SL on the position."))
                default: parts.append(tr("Position opened, but Perpl didn't accept the stop-loss. Set it with TP/SL on the position."))
                }
            } else if resting, let text = restingRefused(takeProfit: refusedTP, stopLoss: refusedSL) {
                parts.append(text)
            } else if let text = refusedUndecided(takeProfit: refusedTP, stopLoss: refusedSL) {
                parts.append(text)
            }
        }
        switch (tp?.unknown == true, sl?.unknown == true) {
        case (true, true): parts.append(tr("Order status unknown for the take-profit and stop-loss — Perpl didn't confirm them. Check Open Orders before placing them again."))
        case (true, false): parts.append(tr("Order status unknown for the take-profit — Perpl didn't confirm it. Check Open Orders before placing it again."))
        case (false, true): parts.append(tr("Order status unknown for the stop-loss — Perpl didn't confirm it. Check Open Orders before placing it again."))
        case (false, false): break
        }
        return parts.isEmpty ? nil : WordWrap.sentences(parts)
    }

    /// A resting limit order's triggers Perpl refused: they can be set once it fills.
    static func restingRefused(takeProfit: Bool, stopLoss: Bool) -> String? {
        switch (takeProfit, stopLoss) {
        case (true, true): return tr(LocalizedStringResource("The order is on the book, but Perpl didn't accept the take-profit and stop-loss. Set them with TP/SL on the position once the order fills.", comment: "A Perps order sheet's warning: the limit order rests on the order book; Perpl refused its take-profit and stop-loss."))
        case (true, false): return tr(LocalizedStringResource("The order is on the book, but Perpl didn't accept the take-profit. Set it with TP/SL on the position once the order fills.", comment: "A Perps order sheet's warning: the limit order rests on the order book; Perpl refused its take-profit."))
        case (false, true): return tr(LocalizedStringResource("The order is on the book, but Perpl didn't accept the stop-loss. Set it with TP/SL on the position once the order fills.", comment: "A Perps order sheet's warning: the limit order rests on the order book; Perpl refused its stop-loss."))
        case (false, false): return nil
        }
    }
}

/// The words of Close Position, Add Margin and Cancel Order sent over the trading connection (one-click), in the app's
/// language: each a whole sentence or a short state with its own key.
enum PerpActionCopy {
    /// Under an error on one of the three sheets: nothing left the device; reopening sends it again (maybe over the
    /// trading connection once it is back).
    static var nothingSent: String {
        tr(LocalizedStringResource("Nothing was sent. Close this and try again.", comment: "Under an error on Close Position / Add Margin / Cancel Order sent over one-click trading: nothing left the device; reopening the sheet sends it again."))
    }

    /// Under an error on one of the three sheets: Perpl's trading connection can't take it now, so the reopened sheet
    /// sends it as a wallet transaction.
    static var nothingSentWallet: String {
        tr(LocalizedStringResource("Nothing was sent. Close this and try again: it will be sent from your wallet.", comment: "Under an error on Close Position / Add Margin / Cancel Order: Perpl's trading connection can't take it now, so reopening the sheet sends it as a wallet transaction."))
    }

    static var marginNotAdded: String {
        tr(LocalizedStringResource("Margin not added", comment: "Add Margin's result headline, also a notification title: Perpl refused to add the margin; the position's margin is unchanged."))
    }

    static var marginNotConfirmed: String {
        tr(LocalizedStringResource("Margin not confirmed yet", comment: "Add Margin's result headline, also a notification title: Perpl hasn't confirmed the margin in time; it may still be added."))
    }

    static var marginCheck: String {
        tr(LocalizedStringResource("Check the position's margin before adding more: Perpl may still add it.", comment: "Detail under \"Margin not confirmed yet\", also that notification's body."))
    }

    static var marginRefused: String {
        tr(LocalizedStringResource("Perpl refused to add the margin.", comment: "Add Margin's error when Perpl refused the request without giving a reason."))
    }

    static var marginOverAvailable: String {
        tr(LocalizedStringResource("That's more than the available balance on your Perpl account, so nothing was sent.", comment: "Add Margin's error: the amount is above what the Perpl account has free right now."))
    }

    static var marginCanClose: String {
        tr(LocalizedStringResource("You can close this. The result will show as a notification and in Activity.", comment: "Under Add Margin's waiting status: the sheet can be closed; the margin's result arrives as a notification and an Activity row."))
    }

    /// Activity row title for margin sent over the trading connection whose result is not confirmed, or refused later.
    static func addMarginTitle(_ symbol: String) -> String {
        tr(LocalizedStringResource("Add \(symbol) margin", comment: "Activity row title for margin sent over the trading connection whose result is not confirmed, or which Perpl refused later. %@ the market's symbol (\"BTC\")."))
    }

    static func marginNotConfirmedSubtitle(_ amount: String) -> String {
        tr(LocalizedStringResource("\(amount) AUSD · result not confirmed — check the position", comment: "Activity row subtitle under \"Add BTC margin\". %@ the amount, formatted (\"25.5\"); AUSD is the collateral token."))
    }

    static func marginNotAddedSubtitle(_ amount: String) -> String {
        tr(LocalizedStringResource("\(amount) AUSD · not added", comment: "Activity row subtitle under \"Add BTC margin\" once Perpl refused it after all. %@ the amount, formatted."))
    }

    static var closeUnknown: String {
        tr(LocalizedStringResource("Close status unknown — Perpl didn't confirm this close, so it may have gone through. Check Positions before closing again.", comment: "Close Position sheet and the Perps status row: the close was sent but Perpl never answered it. Positions is a tab of the Perps screen."))
    }

    // MARK: A resting order's cancel row [tight]

    static var orderCancelled: String {
        tr(LocalizedStringResource("cancelRow.order.cancelled", defaultValue: "Cancelled", comment: "[tight] Cancel Order sheet row and the Orders tab's order card: Perpl's live list confirms the resting ORDER was cancelled (an adjective agreeing with \"order\"; Spanish: orden, feminine)."))
    }

    static var orderStillLive: String {
        tr(LocalizedStringResource("cancelRow.order.stillLive", defaultValue: "Still live", comment: "[tight] Cancel Order sheet row: Perpl refused the cancel, so the ORDER is still active (agreeing with \"order\")."))
    }

    static var orderFilledFirst: String {
        tr(LocalizedStringResource("cancelRow.order.filledFirst", defaultValue: "Filled first", comment: "[tight] Cancel Order sheet row and the order card: the limit ORDER filled before the cancel arrived."))
    }

    static var orderExpiredFirst: String {
        tr(LocalizedStringResource("cancelRow.order.expiredFirst", defaultValue: "Expired first", comment: "[tight] As above: the ORDER had expired before the cancel arrived."))
    }

    static var orderAlreadyGone: String {
        tr(LocalizedStringResource("cancelRow.order.alreadyGone", defaultValue: "Already gone", comment: "[tight] As above: the ORDER was no longer on Perpl when the cancel arrived."))
    }

    static var orderNotConfirmed: String {
        tr(LocalizedStringResource("cancelRow.order.notConfirmed", defaultValue: "Not confirmed", comment: "[tight] As above: Perpl hasn't confirmed the cancel in time; the ORDER may still be active."))
    }

    /// A resting order's cancel, by what Perpl's list showed: the row's short state.
    static func orderState(_ result: PerplCancelResult) -> String {
        switch result {
        case .cancelled: return orderCancelled
        case .refused: return orderStillLive
        case .firedFirst: return orderFilledFirst
        case .expiredFirst: return orderExpiredFirst
        case .alreadyGone: return orderAlreadyGone
        case .notConfirmed: return orderNotConfirmed
        }
    }

    // MARK: A resting order that left Perpl's list with no cancel from this device [tight]

    static var orderFilled: String {
        tr(LocalizedStringResource("orderCard.filled", defaultValue: "Filled", comment: "[tight] The Orders tab's order card, in place of its Cancel button: Perpl's live list shows the resting limit ORDER filled (no cancel was sent from this device). An adjective agreeing with \"order\" (Spanish: orden, feminine)."))
    }

    static var orderExpired: String {
        tr(LocalizedStringResource("orderCard.expired", defaultValue: "Expired", comment: "[tight] As above: Perpl's live list shows the resting ORDER expired."))
    }

    static var orderGone: String {
        tr(LocalizedStringResource("orderCard.gone", defaultValue: "Gone", comment: "[tight] As above: the resting ORDER is no longer on Perpl's live list (it failed or was removed there)."))
    }

    /// A resting order Perpl's list showed leave on its own: the card's short state, never words about a cancel.
    static func orderLeft(_ result: PerplCancelResult) -> String {
        switch result {
        case .cancelled: return orderCancelled
        case .firedFirst: return orderFilled
        case .expiredFirst: return orderExpired
        case .alreadyGone, .refused, .notConfirmed: return orderGone
        }
    }

    // MARK: A resting order's cancel, in a sentence

    static var orderWasCancelled: String {
        tr(LocalizedStringResource("The order was cancelled.", comment: "Cancel Order sheet: Perpl's live list confirms the resting order was cancelled."))
    }

    static func orderCouldntCancel(_ why: String) -> String {
        tr(LocalizedStringResource("Couldn't cancel the order: \(why) It is still live.", comment: "Cancel Order sheet: Perpl refused the cancel; %@ Perpl's reason, one or two whole sentences."))
    }

    static var orderCouldntCancelGeneric: String {
        tr(LocalizedStringResource("Perpl couldn't cancel the order. It is still live.", comment: "Cancel Order sheet: Perpl refused the cancel without a specific reason."))
    }

    static var orderWasAlreadyGone: String {
        tr(LocalizedStringResource("The order was already gone.", comment: "Cancel Order sheet: the order was no longer on Perpl when the cancel would have gone out; nothing was sent, or nothing was there to cancel."))
    }

    static var orderFilledBeforeCancel: String {
        tr(LocalizedStringResource("The order filled before the cancel landed.", comment: "Cancel Order sheet: it filled before Perpl processed the cancel."))
    }

    static var orderHadExpired: String {
        tr(LocalizedStringResource("The order had already expired.", comment: "Cancel Order sheet: it had expired before Perpl processed the cancel."))
    }

    static var orderCancelNotConfirmed: String {
        tr(LocalizedStringResource("Not confirmed yet: Perpl hasn't removed the order. Check Orders: it may still be live.", comment: "Cancel Order sheet: the cancel was sent but Perpl's list didn't confirm it in time. Orders is a tab of the Perps screen."))
    }
}

/// The words of a Perps action signed in the wallet and sent as a transaction on Monad (the on-chain order, Close,
/// Add Margin), whose result is read from its receipt: each a whole sentence or title with its own key.
enum PerpOnChainCopy {
    /// The order's Activity row until its receipt is read.
    static var orderSent: String {
        tr(LocalizedStringResource("Order sent on Monad · result not read", comment: "A Perps Activity row's subtitle, under 'Long BTC-PERP': the order's transaction confirmed on Monad, but what it did (filled or not) hasn't been read from it yet."))
    }

    /// A close's Activity row until its receipt is read.
    static var closeSent: String {
        tr(LocalizedStringResource("Close sent · result not read", comment: "A Perps Activity row's subtitle, under 'Close BTC': the close's transaction confirmed on Monad, but how much of the position it closed hasn't been read from it yet."))
    }

    /// The transaction confirmed and matched nothing (a market order or close with nothing within its slippage).
    static var nothingFilled: String {
        tr(LocalizedStringResource("Confirmed on Monad, but nothing filled", comment: "A Perps Activity row's subtitle, also a sent transaction's status in Recent Activity: the order's transaction confirmed on Monad, but none of the order executed (nothing on the order book within its slippage). Only the network fee was spent."))
    }

    /// The receipt couldn't be read, or what it holds doesn't add up: said plainly, never guessed.
    static var unreadable: String {
        tr(LocalizedStringResource("Confirmed on Monad. The result couldn't be read — check Positions.", comment: "A Perps sheet's result line: the order's transaction confirmed on Monad, but what it did (filled or not) couldn't be read from it. Positions is a tab of the Perps screen."))
    }

    /// Add Margin's result line: the collateral the position received, as its own event reported it.
    static func marginAdded(_ amount: String) -> String {
        tr(LocalizedStringResource("Added \(amount) AUSD margin.", comment: "The Add Margin sheet's result line: the position received this much collateral, read from the transaction. The value: the amount (“25.5”); AUSD is the collateral token's symbol."))
    }

    /// Add Margin's line when the receipt couldn't be read. Never says the margin is missing: the transaction confirmed.
    static var marginUnreadable: String {
        tr(LocalizedStringResource("Confirmed on Monad, but the result couldn't be read. Check the position.", comment: "The Add Margin sheet's result line: the transaction confirmed on Monad, but the margin it added couldn't be read from it. The position card shows its margin."))
    }

    /// A close's Activity title until its result is read, and when nothing filled.
    static func closeTitle(_ symbol: String) -> String {
        tr(LocalizedStringResource("Close \(symbol)", comment: "A Perps Activity row's title: a close sent for the position on that market, its result not read yet or nothing filled. The value: the market's symbol (“BTC”)."))
    }

    /// A close that filled part of the position.
    static func partlyClosedTitle(_ symbol: String) -> String {
        tr(LocalizedStringResource("Partly closed \(symbol)", comment: "A Perps Activity row's title: a close reduced part of the position on that market; the rest is still open. The value: the market's symbol (“BTC”)."))
    }

    /// A close's Activity subtitle: what closed, at the average price.
    static func closedAt(_ amount: String, price: String) -> String {
        tr(LocalizedStringResource("\(amount) closed at \(price)", comment: "A Perps Activity row's subtitle, under 'Closed BTC': the values are the amount closed (“0.001 BTC”) and the average price it closed at."))
    }

    /// A partial close's Activity subtitle.
    static func partlyClosedAt(_ amount: String, of whole: String, price: String) -> String {
        tr(LocalizedStringResource("\(amount) of \(whole) closed at \(price)", comment: "A Perps Activity row's subtitle, under 'Partly closed BTC': the values are the amount closed (“0.001 BTC”), the amount the close was for, and the average price it closed at."))
    }
}
