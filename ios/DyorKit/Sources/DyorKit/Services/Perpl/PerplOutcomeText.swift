import Foundation

/// What an order's result says, in the app's language: a headline and, when there is more to say, a detail of whole
/// sentences, with the tone the sheet's icon, colour and haptic follow. Only what Perpl reported (or, failing that, what
/// the chain showed) is said: a fill without a price never borrows the mark, an unknown result says it is not known, and
/// an order Perpl never answered gets no detail here (the sheet says why its result can't be known yet).
public struct PerplOutcomeText: Sendable, Equatable {
    public let headline: String
    public let detail: String?
    public let tone: PerplOrderOutcome.Tone

    public init(headline: String, detail: String?, tone: PerplOrderOutcome.Tone) {
        self.headline = headline
        self.detail = detail
        self.tone = tone
    }

    /// The order the text is about, as it was sent.
    public struct Context: Sendable {
        /// The market's asset ("BTC"), never translated.
        public let asset: String
        public let priceDecimals: Int
        public let lotDecimals: Int
        public let requestedSize: Double
        /// A limit order's price; nil for a market order.
        public let limitPrice: Double?
        public let isMarket: Bool
        /// Reduce-only, or an order that nets against the position held (`PerpCloseOrder.closes` is not nil): its result
        /// is said of the position, not of a position opened.
        public let reducesPosition: Bool
        public let slippageBps: Int
        /// Perpl answered the entry with mt:3 code 0 (it took the order for forwarding).
        public let acknowledged: Bool

        public init(asset: String, priceDecimals: Int, lotDecimals: Int, requestedSize: Double, limitPrice: Double?, isMarket: Bool,
                    reducesPosition: Bool, slippageBps: Int, acknowledged: Bool) {
            self.asset = asset; self.priceDecimals = priceDecimals; self.lotDecimals = lotDecimals
            self.requestedSize = requestedSize; self.limitPrice = limitPrice; self.isMarket = isMarket
            self.reducesPosition = reducesPosition; self.slippageBps = slippageBps; self.acknowledged = acknowledged
        }
    }

    /// "0.0004 BTC": the size at the market's lot precision, then the asset — passed whole into every sentence, so
    /// translators place the amount, not a bare number and a separate asset.
    public static func amount(_ size: Double, _ c: Context) -> String {
        "\(NumberStyle.number(size, maximumFractionDigits: c.lotDecimals)) \(c.asset)"
    }

    /// A price at the market's precision.
    static func price(_ value: Double, _ c: Context) -> String {
        NumberStyle.number(value, maximumFractionDigits: c.priceDecimals)
    }

    /// A fee in dollars (its size; whether it was paid or paid back is in the sentence).
    static func fee(_ usd: Double) -> String {
        PriceFormat.usdValue(abs(usd), fractionDigits: 2...4)
    }

    /// The result of the ticket's order (AuthedOrderSheet, the trade screen's status row).
    public static func order(_ o: PerplOrderOutcome, _ c: Context) -> PerplOutcomeText {
        PerplOutcomeText(headline: headline(o, c, close: false), detail: detail(o, c, close: false), tone: o.tone)
    }

    /// The result of a close of the position (ClosePositionSheet): said of the position.
    public static func close(_ o: PerplOrderOutcome, _ c: Context) -> PerplOutcomeText {
        PerplOutcomeText(headline: headline(o, c, close: true), detail: detail(o, c, close: true), tone: o.tone)
    }

    /// The line a provisional failure shows under the still-waiting status: Perpl reported a problem, why, and that the
    /// final answer is awaited. Never a headline: a later report may still say the order went through.
    public static func provisional(_ reason: PerplOrderReason) -> String {
        WordWrap.sentences([
            L10n.string(LocalizedStringResource("Perpl reported a problem.", bundle: L10n.kit, comment: "Shown under 'Waiting for Perpl…' while a Perps order the app sent waits for Perpl's final answer: Perpl reported a problem that a later report may still replace. A reason sentence and 'Waiting for its final answer.' follow.")),
            reason.message,
            L10n.string(LocalizedStringResource("Waiting for its final answer.", bundle: L10n.kit, comment: "Ends the line 'Perpl reported a problem. <reason>' under 'Waiting for Perpl…': the app waits for Perpl's final answer about a Perps order it sent.")),
        ])
    }

    // MARK: Headlines

    private static func headline(_ o: PerplOrderOutcome, _ c: Context, close: Bool) -> String {
        switch o {
        case .filled(let fill):
            return close ? closedHeadline(fill, c) : filledHeadline(fill, c)
        case .partlyFilled(let fill, _):
            let filled = amount(fill.size(lotDecimals: c.lotDecimals), c)
            let ordered = amount(Double(fill.requestedSizeRaw) / pow(10, Double(c.lotDecimals)), c)
            if let p = fill.price(priceDecimals: c.priceDecimals), p > 0 {
                let at = price(p, c)
                return close
                    ? L10n.string(LocalizedStringResource("Partly closed \(filled) of \(ordered) at \(at)", bundle: L10n.kit, comment: "The result of a Perps close the app sent, shown in the close sheet's result line: the position was reduced by part of the size sent. The values: the amount closed (“0.001 BTC”), the amount the close was for, the average price it closed at."))
                    : L10n.string(LocalizedStringResource("Partly filled \(filled) of \(ordered) at \(at)", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: part of it filled. The values: the amount filled (“0.001 BTC”), the amount ordered, the average fill price."))
            }
            return close
                ? L10n.string(LocalizedStringResource("Partly closed \(filled) of \(ordered)", bundle: L10n.kit, comment: "The result of a Perps close the app sent, shown in the close sheet's result line: the position was reduced by part of the size sent (price unknown). The values: the amount closed (“0.001 BTC”), the amount the close was for."))
                : L10n.string(LocalizedStringResource("Partly filled \(filled) of \(ordered)", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: part of it filled (price unknown). The values: the amount filled (“0.001 BTC”), the amount ordered."))
        case .resting:
            guard let limit = c.limitPrice, limit > 0 else { return PerpOrderNotice.placed.title }
            let at = price(limit, c)
            return close
                ? L10n.string(LocalizedStringResource("Close order resting on the book at \(at)", bundle: L10n.kit, comment: "The result of a Perps close the app sent, shown in the close sheet's result line: a limit close now waits on the order book. The value: its limit price."))
                : L10n.string(LocalizedStringResource("Resting on the book at \(at)", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: a limit order now waits on the order book. The value: its limit price."))
        case .notFilled:
            return close
                ? notClosedHeadline
                : L10n.string(LocalizedStringResource("Not filled", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: none of it executed."))
        case .failed:
            return close ? notClosedHeadline : PerpOrderNotice.failed.title
        case .expired:
            return close
                ? notClosedHeadline
                : L10n.string(LocalizedStringResource("Order expired", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: its time on Perpl ran out before it filled."))
        case .cancelled:
            return L10n.string(LocalizedStringResource("Order cancelled", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: it was cancelled before it filled (from Orders, or in the Perpl web app)."))
        case .observed(let growth):
            let grown = amount(growth.size, c)
            return L10n.string(LocalizedStringResource("Position grew by \(grown)", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row, when Perpl's own report is missing but the position on Monad grew. The value: how much it grew by (“0.001 BTC”)."))
        case .unconfirmed:
            return unconfirmedHeadline
        case .armed:
            return PerpOrderNotice.placed.title
        case .triggered:
            return PerpOrderNotice.submitted.title
        }
    }

    /// "Not closed": a close that executed nothing (the sheet's result line, and the close's notice title).
    public static var notClosedHeadline: String {
        L10n.string(LocalizedStringResource("Not closed", bundle: L10n.kit, comment: "The result of a Perps close the app sent, shown in the close sheet's result line: none of it executed, the position is still open."))
    }

    static var unconfirmedHeadline: String {
        L10n.string(LocalizedStringResource("Result not confirmed yet", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: Perpl's result hasn't arrived; the line under it says what to check."))
    }

    private static func filledHeadline(_ fill: PerplFillSummary, _ c: Context) -> String {
        let filled = amount(fill.size(lotDecimals: c.lotDecimals), c)
        guard let p = fill.price(priceDecimals: c.priceDecimals), p > 0 else {
            return L10n.string(LocalizedStringResource("Filled \(filled)", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: it filled (price unknown). The value: the amount filled (“0.001 BTC”)."))
        }
        let at = price(p, c)
        guard let usd = fill.feeUSD else {
            return L10n.string(LocalizedStringResource("Filled \(filled) at \(at)", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: it filled (fee unknown). The values: the amount filled (“0.001 BTC”), the average fill price."))
        }
        let fee = fee(usd)
        return usd < 0
            ? L10n.string(LocalizedStringResource("Filled \(filled) at \(at) · rebate \(fee)", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: it filled. The values: the amount filled (“0.001 BTC”), the average fill price, the rebate in dollars (Perpl paid the fee back)."))
            : L10n.string(LocalizedStringResource("Filled \(filled) at \(at) · fee \(fee)", bundle: L10n.kit, comment: "The result of a Perps order the app sent, shown in the order sheet's result line and the trade screen's status row: it filled. The values: the amount filled (“0.001 BTC”), the average fill price, the fee in dollars."))
    }

    private static func closedHeadline(_ fill: PerplFillSummary, _ c: Context) -> String {
        let closed = amount(fill.size(lotDecimals: c.lotDecimals), c)
        guard let p = fill.price(priceDecimals: c.priceDecimals), p > 0 else {
            return L10n.string(LocalizedStringResource("Closed \(closed)", bundle: L10n.kit, comment: "The result of a Perps close the app sent, shown in the close sheet's result line: the position was reduced by this amount (price unknown). The value: the amount closed (“0.001 BTC”)."))
        }
        let at = price(p, c)
        guard let usd = fill.feeUSD else {
            return L10n.string(LocalizedStringResource("Closed \(closed) at \(at)", bundle: L10n.kit, comment: "The result of a Perps close the app sent, shown in the close sheet's result line: the position was reduced by this amount (fee unknown). The values: the amount closed (“0.001 BTC”), the average price it closed at."))
        }
        let fee = fee(usd)
        return usd < 0
            ? L10n.string(LocalizedStringResource("Closed \(closed) at \(at) · rebate \(fee)", bundle: L10n.kit, comment: "The result of a Perps close the app sent, shown in the close sheet's result line: the position was reduced by this amount. The values: the amount closed (“0.001 BTC”), the average price it closed at, the rebate in dollars (Perpl paid the fee back)."))
            : L10n.string(LocalizedStringResource("Closed \(closed) at \(at) · fee \(fee)", bundle: L10n.kit, comment: "The result of a Perps close the app sent, shown in the close sheet's result line: the position was reduced by this amount. The values: the amount closed (“0.001 BTC”), the average price it closed at, the fee in dollars."))
    }

    // MARK: Details

    private static func detail(_ o: PerplOrderOutcome, _ c: Context, close: Bool) -> String? {
        let slippage = NumberStyle.basisPoints(c.slippageBps)
        switch o {
        case .filled, .resting, .armed, .triggered:
            return nil
        case .partlyFilled(_, let rest):
            switch rest {
            case .cancelled(let reason) where reason.reason == 16:
                return close
                    ? L10n.string(LocalizedStringResource("The rest wasn't filled within \(slippage). That part of your position is still open.", bundle: L10n.kit, comment: "The result of a Perps close the app sent, under 'Partly closed …' in the close sheet: the rest found nothing on the order book within the slippage. The value: the slippage (“1%”)."))
                    : L10n.string(LocalizedStringResource("The rest was cancelled: there wasn't enough on the order book within your \(slippage) slippage.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Partly filled …' in the order sheet and the trade screen's status row: the unfilled rest was cancelled. The value: the order's slippage (“1%”)."))
            case .cancelled:
                return L10n.string(LocalizedStringResource("The rest was cancelled.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Partly filled …' in the order sheet and the trade screen's status row: the unfilled rest of the order was cancelled."))
            case .resting:
                guard let limit = c.limitPrice, limit > 0 else { return nil }
                let at = price(limit, c)
                return L10n.string(LocalizedStringResource("The rest is resting on the book at \(at).", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Partly filled …' in the order sheet and the trade screen's status row: the unfilled rest waits on the order book. The value: the limit price."))
            case .expired:
                return L10n.string(LocalizedStringResource("The rest expired before it filled.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Partly filled …' in the order sheet and the trade screen's status row: the unfilled rest ran out of time on Perpl."))
            }
        case .notFilled(let reason):
            if reason.reason == 16 {
                if close {
                    return L10n.string(LocalizedStringResource("Nothing on the order book within \(slippage). Your position is still open. Try again, or close with a limit order.", bundle: L10n.kit, comment: "The result of a Perps close the app sent, under 'Not closed' in the close sheet: nothing on the order book within the slippage. The value: the slippage (“1%”)."))
                }
                return c.reducesPosition
                    ? L10n.string(LocalizedStringResource("There wasn't enough on the order book within your \(slippage) slippage. Your position is unchanged.", bundle: L10n.kit, comment: "The result of a Perps order the app sent that reduces the position, under 'Not filled' in the order sheet and the trade screen's status row. The value: the order's slippage (“1%”)."))
                    : L10n.string(LocalizedStringResource("There wasn't enough on the order book within your \(slippage) slippage, so nothing was opened.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Not filled' in the order sheet and the trade screen's status row. The value: the order's slippage (“1%”)."))
            }
            return WordWrap.sentences(reason.message, unchanged(c, close: close))
        case .failed(let reason):
            // A reason that already says nothing was placed needs no second sentence saying so.
            guard ![14, 15, 32, 59].contains(reason.reason) || reason.failure != nil else { return reason.message }
            return WordWrap.sentences(reason.message, unchanged(c, close: close))
        case .expired:
            if close || c.reducesPosition {
                return L10n.string(LocalizedStringResource("It expired before it filled. Your position is unchanged.", bundle: L10n.kit, comment: "The result of a Perps order the app sent that reduces the position, under 'Order expired' or 'Not closed': its time on Perpl ran out before it filled."))
            }
            return L10n.string(LocalizedStringResource("It expired before it filled, so nothing was opened.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Order expired' in the order sheet and the trade screen's status row: its time on Perpl ran out before it filled."))
        case .cancelled:
            return L10n.string(LocalizedStringResource("It was cancelled before it filled.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Order cancelled' in the order sheet and the trade screen's status row."))
        case .observed(let growth):
            if let p = growth.price, p > 0 {
                let at = price(p, c)
                return L10n.string(LocalizedStringResource("At about \(at). Perpl's own report for this order hasn't arrived yet.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Position grew by …' in the order sheet and the trade screen's status row: the price the growth implies, read from the position on Monad. The value: that price."))
            }
            return L10n.string(LocalizedStringResource("Perpl's own report for this order hasn't arrived yet.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Position grew by …' in the order sheet and the trade screen's status row: the growth was read from the position on Monad."))
        case .unconfirmed(let why):
            // An order Perpl never answered: the sheet says why its result can't be known (GL-1), never "accepted".
            guard c.acknowledged else { return nil }
            if close {
                switch why {
                case .timedOut:
                    return L10n.string(LocalizedStringResource("Perpl accepted the close for forwarding but hasn't reported what happened to it yet. Your positions are reloading: check them before closing again.", bundle: L10n.kit, comment: "The result of a Perps close the app sent, under 'Result not confirmed yet' in the close sheet and the trade screen's status row: Perpl took the close but its result didn't arrive in time."))
                case .connectionLost:
                    return L10n.string(LocalizedStringResource("The connection to Perpl dropped before it reported the close's result. Your positions are reloading: check them before closing again.", bundle: L10n.kit, comment: "The result of a Perps close the app sent, under 'Result not confirmed yet' in the close sheet and the trade screen's status row: the trading connection closed before Perpl reported the close's result."))
                case .foreignReport:
                    return L10n.string(LocalizedStringResource("Perpl reported a different order under this close's request number, so its result can't be shown. Check Positions before closing again.", bundle: L10n.kit, comment: "The result of a Perps close the app sent, under 'Result not confirmed yet' in the close sheet and the trade screen's status row: what Perpl reported under the close's request number doesn't match the close sent. Positions is a tab of the Perps screen."))
                }
            }
            switch why {
            case .timedOut:
                return L10n.string(LocalizedStringResource("Perpl accepted the order for forwarding but hasn't reported what happened to it yet. Your positions and orders are reloading: check them before placing it again.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Result not confirmed yet' in the order sheet and the trade screen's status row: Perpl took the order but its result didn't arrive in time."))
            case .connectionLost:
                return L10n.string(LocalizedStringResource("The connection to Perpl dropped before it reported the result. Your positions and orders are reloading: check them before placing it again.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Result not confirmed yet' in the order sheet and the trade screen's status row: the trading connection closed before Perpl reported the result."))
            case .foreignReport:
                return L10n.string(LocalizedStringResource("Perpl reported a different order under this order's request number, so its result can't be shown. Check Positions and Orders before placing it again.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, under 'Result not confirmed yet' in the order sheet and the trade screen's status row: what Perpl reported under the order's request number doesn't match the order sent. Positions and Orders are tabs of the Perps screen."))
            }
        }
    }

    /// What a reason sentence is followed by when nothing executed: nothing was opened, or the position is unchanged.
    private static func unchanged(_ c: Context, close: Bool) -> String {
        if close {
            return L10n.string(LocalizedStringResource("Your position is still open.", bundle: L10n.kit, comment: "The result of a Perps close the app sent, after a reason sentence in the close sheet: none of the close executed."))
        }
        return c.reducesPosition
            ? L10n.string(LocalizedStringResource("Your position is unchanged.", bundle: L10n.kit, comment: "The result of a Perps order the app sent that reduces the position, after a reason sentence ('Not filled', 'Order failed'): nothing executed."))
            : L10n.string(LocalizedStringResource("Nothing was opened.", bundle: L10n.kit, comment: "The result of a Perps order the app sent, after a reason sentence ('Not filled', 'Order failed'): nothing executed, no position was opened."))
    }
}
