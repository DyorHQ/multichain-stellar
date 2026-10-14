import Foundation

/* Take-profit / stop-loss rules for Perpl, kept pure so the order ticket, the position TP/SL sheet and the tests share
   one definition. A trigger is a reduce-only close that Perpl's keeper fires when the price crosses it, so a bad one is
   worse than none: a zero or wrong-sided price fires the moment it is admitted, and a stop beyond the liquidation price
   never fires before the position is liquidated. Each is refused before anything is sent. */

public enum PerplTriggerKind: String, Sendable, Codable, CaseIterable {
    case takeProfit, stopLoss
}

public enum PerplTriggerRules {
    /// Why a trigger price can't be used. The app words these; the values carry what the message needs.
    public enum Problem: Equatable, Sendable {
        /// Zero, negative, or smaller than one price tick (it would be sent as `tp: 0`).
        case tooLow(PerplTriggerKind, minimum: Double)
        /// Not a whole number of ticks at the market's price precision.
        case offTick(PerplTriggerKind, decimals: Int)
        /// Not a finite price this market can represent.
        case outOfRange(PerplTriggerKind)
        /// On the wrong side of the reference price for this position side: it would fire at once.
        case wrongSide(PerplTriggerKind, side: PositionSide, reference: Double)
        /// A stop-loss at or beyond the position's liquidation price: liquidation comes first, so it protects nothing.
        case beyondLiquidation(side: PositionSide, liquidation: Double)
        /// Take-profit / stop-loss on a reduce-only order: its triggers would close the opposite side, which the
        /// account doesn't hold.
        case reduceOnly
        /// Take-profit / stop-loss on an order that only shrinks the open position on the other side (`position` is
        /// that position's side): like a reduce-only order, it opens nothing for its triggers to close.
        case reducesPosition(PositionSide)
    }

    /// Whether an order of `size` on `side` only shrinks an open position of `positionSize` on the other side
    /// (security audit GT-6): Perpl activates the order's triggers when it trades, and they would then close a position
    /// on `side` the account doesn't hold. An order larger than the position turns it around, and its triggers close
    /// what is left on the new side (Perpl clamps a close to the position).
    public static func onlyReduces(side: PositionSide, size: Double, positionSide: PositionSide?, positionSize: Double) -> Bool {
        guard let positionSide, positionSide != side, positionSize > 0, size > 0 else { return false }
        return size <= positionSize * (1 + 1e-9)
    }

    /// Why a stop-loss is refused while the market's maintenance margin (so the liquidation price) can't be read: it
    /// can't be checked against liquidation. A take-profit doesn't depend on it. In the app's language.
    public static var liquidationUnknownMessage: String {
        L10n.tr("The liquidation price can't be read right now, so this stop-loss can't be checked against it. Try again in a moment.")
    }

    /// The price as a whole number of ticks (`price × 10^decimals`), or nil when it isn't one: off the tick grid,
    /// below one tick, or not representable.
    public static func ticks(_ price: Double, decimals: Int) -> Int? {
        guard price.isFinite, price > 0 else { return nil }
        let scaled = price * pow(10, Double(decimals))
        let rounded = scaled.rounded()
        // Binary floating point: 95000.1 × 10 is 950001.0000000001. Anything further off than that is a real fraction.
        guard rounded >= 1, abs(scaled - rounded) <= max(1e-6, rounded * 1e-9) else { return nil }
        return Int(exactly: rounded)
    }

    /// The problem with a trigger at `price` for a `side` position, or nil.
    /// - reference: the price it is measured against — the entry for a new order (its limit price, else the mark), or
    ///   the current mark for a trigger added to an open position (it must not fire the moment it is placed).
    /// - liquidation: the position's (estimated) liquidation price; a stop-loss must sit strictly inside it.
    public static func problem(_ kind: PerplTriggerKind, price: Double, side: PositionSide, reference: Double,
                               liquidation: Double?, priceDecimals: Int) -> Problem? {
        let tick = pow(10, -Double(priceDecimals))
        // No market prices anywhere near 10^15 ticks; past that the scaled integer stops being exact.
        guard price.isFinite, price * pow(10, Double(priceDecimals)) < 1e15 else { return .outOfRange(kind) }
        guard price >= tick * 0.999_999 else { return .tooLow(kind, minimum: tick) }
        guard ticks(price, decimals: priceDecimals) != nil else { return .offTick(kind, decimals: priceDecimals) }
        if reference > 0 {
            // A long takes profit above and stops out below; a short the reverse.
            let above = price > reference
            let below = price < reference
            let ok: Bool
            switch (kind, side) {
            case (.takeProfit, .long), (.stopLoss, .short): ok = above
            case (.takeProfit, .short), (.stopLoss, .long): ok = below
            }
            if !ok { return .wrongSide(kind, side: side, reference: reference) }
        }
        if kind == .stopLoss, let liquidation, liquidation > 0, liquidation.isFinite {
            let inside = side == .long ? price > liquidation : price < liquidation
            if !inside { return .beyondLiquidation(side: side, liquidation: liquidation) }
        }
        return nil
    }
}

extension PerplTriggerRules.Problem {
    /// What to tell the user, in the app's language. `referenceName` names the price a wrong-sided trigger is measured
    /// against ("the mark price"); nil names the entry. Each case is a whole sentence for each trigger and side, so no
    /// word is put into another language's sentence in English.
    public func message(market: PerpMarket, referenceName: String? = nil) -> String {
        let asset = market.asset
        switch self {
        case .tooLow(let kind, let minimum):
            let minimum = NumberStyle.number(minimum)
            return kind == .takeProfit ? L10n.tr("Take-profit must be at least \(minimum) on \(asset).")
                : L10n.tr("Stop-loss must be at least \(minimum) on \(asset).")
        case .offTick(let kind, let decimals) where decimals == 0:
            return kind == .takeProfit ? L10n.tr("Take-profit must be a whole number on \(asset).") : L10n.tr("Stop-loss must be a whole number on \(asset).")
        case .offTick(let kind, let decimals):
            return kind == .takeProfit ? L10n.tr("Take-profit can have at most \(decimals) decimal places on \(asset).")
                : L10n.tr("Stop-loss can have at most \(decimals) decimal places on \(asset).")
        case .outOfRange(let kind):
            return kind == .takeProfit ? L10n.tr("Take-profit is not a valid price.") : L10n.tr("Stop-loss is not a valid price.")
        case .wrongSide(let kind, let side, let reference):
            // A long takes profit above and stops out below; a short the reverse.
            let name = referenceName ?? L10n.string(LocalizedStringResource("your entry", bundle: L10n.kit,
                comment: "Completes a sentence about where a take-profit or stop-loss must sit: “… above your entry (950) for a long”."))
            let price = NumberStyle.number(reference)
            switch (kind, side) {
            case (.takeProfit, .long): return L10n.tr("Take-profit must be above \(name) (\(price)) for a long.")
            case (.takeProfit, .short): return L10n.tr("Take-profit must be below \(name) (\(price)) for a short.")
            case (.stopLoss, .long): return L10n.tr("Stop-loss must be below \(name) (\(price)) for a long.")
            case (.stopLoss, .short): return L10n.tr("Stop-loss must be above \(name) (\(price)) for a short.")
            }
        case .beyondLiquidation(let side, let liquidation):
            let price = NumberStyle.number(liquidation)
            return side == .long
                ? L10n.tr("Stop-loss must be above the liquidation price (\(price)). Liquidation would come first, so it would never protect you.")
                : L10n.tr("Stop-loss must be below the liquidation price (\(price)). Liquidation would come first, so it would never protect you.")
        case .reduceOnly:
            return L10n.tr("Take-profit and stop-loss can't be attached to a reduce-only order. Set them on the position instead.")
        case .reducesPosition(let side):
            return side == .long
                ? L10n.tr("This order only reduces your long, so its take-profit and stop-loss would have no short to close and would stay armed for your next short here. Set them with TP/SL on the position instead.")
                : L10n.tr("This order only reduces your short, so its take-profit and stop-loss would have no long to close and would stay armed for your next long here. Set them with TP/SL on the position instead.")
        }
    }
}

/// Which of the account's keeper triggers no longer protect anything. Perpl cancels a trigger linked to a position
/// (`lp`) when that position closes, but a trigger linked to its entry request (`tr`, how the order ticket attaches
/// TP/SL) is not documented to go with it — left armed, it would fire against the next position on that side.
public enum PerplTriggerCleanup {
    /// The sides where a resting entry (a limit OpenLong / OpenShort) could still open a position. The triggers closing
    /// that side of that market may be waiting on the entry, so none of them is treated as orphaned. Only that side: a
    /// resting short says nothing about the stop-loss of a long that is gone.
    public static func restingEntrySides(_ orders: [PerplOpenOrder]) -> Set<PerplMarketSide> {
        Set(orders.filter(\.isRestingEntry).map(\.side))
    }

    /// The reduce-only triggers with no open position on the side they close and no resting entry on that side. One
    /// that has already fired (Triggered, 9) is the keeper's to finish, never touched.
    public static func orphans(orders: [PerplOpenOrder], positions: [PerplLivePosition], extraRestingEntries: Set<PerplMarketSide> = []) -> [PerplOpenOrder] {
        let resting = restingEntrySides(orders).union(extraRestingEntries)
        let open = Set(positions.filter(\.isOpen).map { PerplMarketSide(marketId: $0.marketId, isLong: $0.isLong) })
        return orders.filter { order in
            order.isTrigger && order.isReduceOnly && order.statusRaw != 9 && !resting.contains(order.side) && !open.contains(order.side)
        }
    }

    /// The triggers to cancel because `ended` closed: the orphans on its market that closed its side.
    public static func siblings(of ended: PerplLivePosition, orders: [PerplOpenOrder], positions: [PerplLivePosition], extraRestingEntries: Set<PerplMarketSide> = []) -> [PerplOpenOrder] {
        orphans(orders: orders, positions: positions, extraRestingEntries: extraRestingEntries)
            .filter { $0.marketId == ended.marketId && $0.protectsLong == ended.isLong }
    }
}
