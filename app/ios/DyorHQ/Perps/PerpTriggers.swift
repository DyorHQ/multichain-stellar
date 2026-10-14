import DyorKit
import Foundation

/// A take-profit / stop-loss the app placed for the user, remembered on this device. Perpl holds TP/SL as keeper-managed
/// trigger orders (the on-chain Exchange has no trigger primitive), and the trading socket's open-orders stream (mt:23/24)
/// is the authority for them; this echo only fills in for a trigger the stream hasn't shown yet, and — while the stream
/// isn't live — stands in as an UNVERIFIED record (it may have fired or been cancelled since). Never authoritative.
struct PlacedTrigger: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case takeProfit, stopLoss
        /// The kind's name, in the app's language.
        var label: String { self == .takeProfit ? tr("Take Profit") : tr("Stop Loss") }
        init(_ kind: PerplTriggerKind) { self = kind == .takeProfit ? .takeProfit : .stopLoss }
    }

    let id: UUID
    let perpId: Int
    let symbol: String
    let kind: Kind
    let price: Double
    let size: Double
    /// The side of the position the trigger protects (true = long), for context/labelling.
    let positionLong: Bool
    let placedAt: Date

    init(perpId: Int, symbol: String, kind: Kind, price: Double, size: Double, positionLong: Bool, placedAt: Date = Date()) {
        self.id = UUID()
        self.perpId = perpId
        self.symbol = symbol
        self.kind = kind
        self.price = price
        self.size = size
        self.positionLong = positionLong
        self.placedAt = placedAt
    }
}

/// Per-wallet persistence of app-placed TP/SL triggers (UserDefaults; public numbers only, no keys).
enum TriggerStore {
    private static func key(_ owner: Address?) -> String { "perp.triggers.v1." + (owner?.checksummed.lowercased() ?? "none") }
    /// A market entry needs a little time to settle into a position; don't prune a freshly-placed trigger before the
    /// position it protects has had a chance to appear in the poll.
    private static let settleGrace: TimeInterval = 120

    static func all(owner: Address?) -> [PlacedTrigger] {
        guard let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([PlacedTrigger].self, from: data)) ?? []
    }

    private static func save(_ list: [PlacedTrigger], owner: Address?) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(owner))
    }

    /// Record freshly-accepted triggers. Nothing earlier is dropped: a new entry's take-profit does NOT replace an older
    /// one on Perpl — both stay live, each sized to its own entry — so both echoes stay too (security audit GT-1).
    /// Returns what was recorded, so the order that placed them can later remove its own echoes only (`remove(ids:)`).
    @discardableResult
    static func record(_ new: [PlacedTrigger], owner: Address?) -> [PlacedTrigger] {
        guard !new.isEmpty else { return [] }
        // Bounded: the newest 200 are plenty to stand in for a market's triggers while the stream is offline.
        save(Array((all(owner: owner) + new).suffix(200)), owner: owner)
        return new
    }

    /// Drop exactly these echoes: one order's own take-profit or stop-loss that will never be live (its own result said
    /// so, or a live list read after its entry executed nothing). Every other echo of that kind on that side stays: it
    /// stands for another order's trigger, which is still live on Perpl (GT-1, GT-3).
    static func remove(ids: Set<UUID>, owner: Address?) {
        guard !ids.isEmpty else { return }
        let list = all(owner: owner)
        let kept = list.filter { !ids.contains($0.id) }
        if kept.count != list.count { save(kept, owner: owner) }
    }

    /// Drop the echoes of one kind on one side of a market, once Perpl admitted the cancel of every live trigger they
    /// could stand for (the position TP/SL sheet replaced or removed them).
    static func remove(perpId: Int, kind: PlacedTrigger.Kind, positionLong: Bool, owner: Address?) {
        let list = all(owner: owner)
        let kept = list.filter { !($0.perpId == perpId && $0.kind == kind && $0.positionLong == positionLong) }
        if kept.count != list.count { save(kept, owner: owner) }
    }

    /// Keep a trigger while its market still has an open position OR a resting entry order (or it is too fresh to have
    /// settled yet); drop it otherwise. Pruning needs `verified`: only while the trading stream is live can the app
    /// tell a trigger is gone — offline, a leftover echo may be the only trace of a trigger still armed at Perpl, so
    /// it is kept and shown as unverified (security audit GT-3). Returns — and persists — the survivors.
    @discardableResult
    static func reconcile(owner: Address?, openPerpIds: Set<Int>, verified: Bool) -> [PlacedTrigger] {
        let now = Date()
        let list = all(owner: owner)
        guard verified else { return list }
        let kept = list.filter { openPerpIds.contains($0.perpId) || now.timeIntervalSince($0.placedAt) < settleGrace }
        if kept.count != list.count { save(kept, owner: owner) }
        return kept
    }
}

/// Perps text built in code, in the app's language: a position's side with its size, a trigger with its price, and the
/// word for a figure that can't be computed. Numbers keep the app's one style (`NumberStyle`).
enum PositionText {
    /// "Long 0.5 BTC" or "Short 0.5 BTC".
    static func amount(isLong: Bool, size: Double, asset: String) -> String {
        let amount = "\(NumberStyle.number(size)) \(asset)"
        return isLong
            ? tr(LocalizedStringResource("Long \(amount)", comment: "A long position or order on what follows: “Long 0.5 BTC”, “Long BTC”, “Long BTC-PERP”."))
            : tr(LocalizedStringResource("Short \(amount)", comment: "A short position or order on what follows: “Short 0.5 BTC”, “Short BTC”, “Short BTC-PERP”."))
    }

    /// "TP 72,000" or "SL 61,500": a take-profit or stop-loss at its price, in a summary line.
    static func trigger(_ takeProfit: Bool, at price: Double) -> String {
        let at = NumberStyle.number(price)
        return takeProfit
            ? tr(LocalizedStringResource("TP \(at)", comment: "A take-profit (TP) at its price, in a summary line. [tight]"))
            : tr(LocalizedStringResource("SL \(at)", comment: "A stop-loss (SL) at its price, in a summary line. [tight]"))
    }

    /// A liquidation price that can't be computed: the market's maintenance margin couldn't be read.
    static var unknown: String {
        tr(LocalizedStringResource("Unknown", comment: "A liquidation price that can't be computed. [tight]"))
    }
}
