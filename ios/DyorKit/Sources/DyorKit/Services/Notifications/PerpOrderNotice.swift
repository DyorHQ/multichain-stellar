import Foundation

/// What the app's notification about a perp order says. Perpl acknowledging an order is not a fill: a market order is
/// "submitted" until a position read sees it filled, and a limit order is "placed" on the book. Only evidence that it
/// executed says "filled": a position that opened or grew (`AlertCenter`'s position read), or Perpl's own report of the
/// order's fill on the trading stream (`init(evidence:)`). An acknowledgement never becomes one.
public enum PerpOrderNotice: Hashable, Sendable, CaseIterable {
    /// Perpl acknowledged a market order; nothing is known to have filled yet.
    case submitted
    /// Perpl acknowledged a limit order, which rests on the book.
    case placed
    /// A position read saw the position open or grow, or Perpl reported the order filled.
    case filled
    /// Perpl reported part of the order filled; the rest was cancelled, expired or still rests on the book.
    case partlyFilled
    /// Perpl reported that none of the order executed (nothing within the slippage, or it expired).
    case notFilled
    /// Perpl refused the order after taking it for forwarding: nothing was opened.
    case failed

    /// The notice for Perpl's acknowledgement of an order of `kind`: "submitted" for a market order, "placed" for a
    /// limit order, never "filled".
    public init(acknowledged kind: OrderKind) {
        switch kind {
        case .market: self = .submitted
        case .limit: self = .placed
        }
    }

    /// The notice for what Perpl (or, failing its report, the chain) showed the order did: filled or a position that
    /// grew by what only this order explains → filled; partly filled → partly filled; resting → placed; nothing executed
    /// (not filled, expired) → not filled; refused → failed. Nil when there is nothing to tell: a cancelled order (the
    /// user cancelled it), a take-profit or stop-loss state, a result that isn't known, or a growth another order may
    /// have made (it isn't this order's fill to announce).
    public init?(evidence outcome: PerplOrderOutcome) {
        switch outcome {
        case .observed(let growth) where !growth.attributable: return nil
        case .filled, .observed: self = .filled
        case .partlyFilled: self = .partlyFilled
        case .resting: self = .placed
        case .notFilled, .expired: self = .notFilled
        case .failed: self = .failed
        case .cancelled, .armed, .triggered, .unconfirmed: return nil
        }
    }

    public var title: String {
        switch self {
        case .submitted: return L10n.string(LocalizedStringResource("Order submitted", bundle: L10n.kit, comment: "A notification's title: Perpl acknowledged a market order, which may not have filled yet."))
        case .placed: return L10n.string(LocalizedStringResource("Order placed", bundle: L10n.kit, comment: "A notification's title: Perpl acknowledged a limit order, which now rests on the order book."))
        case .filled: return L10n.string(LocalizedStringResource("Order filled", bundle: L10n.kit, comment: "A notification's title: a position opened or grew, so the order was filled (executed)."))
        case .partlyFilled: return L10n.string(LocalizedStringResource("Order partly filled", bundle: L10n.kit, comment: "A notification's title: Perpl filled part of a Perps order the app sent; the rest was cancelled, expired or still rests on the order book."))
        case .notFilled: return L10n.string(LocalizedStringResource("Order not filled", bundle: L10n.kit, comment: "A notification's title: Perpl executed none of a Perps order the app sent (nothing on the order book within the slippage, or it expired)."))
        case .failed: return L10n.string(LocalizedStringResource("Order failed", bundle: L10n.kit, comment: "A notification's title, also the result headline of the order sheet: Perpl refused a Perps order the app sent after taking it for forwarding; nothing was opened."))
        }
    }
}
