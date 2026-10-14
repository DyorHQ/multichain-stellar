import DyorKit
import Foundation
import Observation

/// The orders sent from this device and what Perpl or the chain showed they did: for the order sheets and the trade
/// screen's status row. In memory (the orders still waiting or able to change, and the newest few others) plus
/// `PerplPendingOrderStore`, so an order whose sheet closed, or whose app was suspended or killed, still gets its result.
/// Never a source for positions: the chain stays the single source of the position cards.
///
/// The decisions are DyorKit's (`PerplTracker`); `PerplTrading` waits on the stream and hands the effects here. This
/// file carries out the order's own notice, its one Activity row and its trigger echoes; the rest goes back to
/// `PerplTrading` (`perform`).
@Observable
@MainActor
final class PerplOrderTracker {
    /// Every order this process knows, of any account (an order outlives an account switch: its result is still filed
    /// under the account it was sent for). The screens read the bound account's only.
    private(set) var orders: [PerplTrackedOrder] = []
    /// The account the screens show.
    @ObservationIgnored private(set) var owner: Address?
    /// Orders read back from the store at `load` that no live task follows: reconciled on the next return or reconnect.
    @ObservationIgnored private(set) var loadedFromDisk: Set<UUID> = []
    /// How many settled orders are kept in memory besides those still waiting or able to change.
    static let settledKept = 20
    #if DEBUG && targetEnvironment(simulator)
    /// The scripted demo's "Would notify" list (`PerplTrading.debugAdopt`): the notice an order with no account would post.
    @ObservationIgnored var debugNotice: ((_ title: String, _ body: String) -> Void)?
    #endif

    func order(_ id: UUID) -> PerplTrackedOrder? { orders.first { $0.id == id } }

    /// The bound account's order the trade screen's status row shows for `marketId` (`PerplTracker.bannerOrder`).
    func bannerOrder(marketId: Int, now: Date) -> PerplTrackedOrder? {
        PerplTracker.bannerOrder(orders.filter { $0.owner == owner }, marketId: marketId, now: now)
    }

    /// The order's sheet is (or is no longer) on screen: while it is, its result shows there, not on the status row.
    func setPresented(_ id: UUID, _ presented: Bool) {
        mutate(id) { $0.presentedInSheet = presented }
    }

    func dismissBanner(_ id: UUID) { mutate(id) { $0.bannerDismissed = true } }

    /// Starts following `order` (persisted at once).
    func add(_ order: PerplTrackedOrder) {
        orders.removeAll { $0.id == order.id }
        orders.append(order)
        prune()
        Self.persist(order)
    }

    /// The order as it stands now (persisted while its result can still change; dropped from the store once final).
    func update(_ order: PerplTrackedOrder) {
        guard let index = orders.firstIndex(where: { $0.id == order.id }) else { return }
        orders[index] = order
        Self.persist(order)
        prune()
    }

    /// Stops keeping `id` in the store (a reconciled order whose result is final, or which aged out).
    func forget(_ id: UUID) {
        loadedFromDisk.remove(id)
        guard let order = order(id), let owner = order.owner else { return }
        PerplPendingOrderStore.remove(id, owner: owner)
    }

    /// Follows the account the screens show: its stored orders are read back (not followed by any task in this
    /// process), to be reconciled on the next return to the app or reconnect.
    func load(owner: Address?) {
        guard owner != self.owner else { return }
        self.owner = owner
        guard let owner else { return }
        for var stored in PerplPendingOrderStore.all(owner: owner) where order(stored.id) == nil {
            // A sheet open when the app was killed is not open now.
            stored.presentedInSheet = false
            orders.append(stored)
            loadedFromDisk.insert(stored.id)
        }
        prune()
    }

    private func mutate(_ id: UUID, _ change: (inout PerplTrackedOrder) -> Void) {
        guard let index = orders.firstIndex(where: { $0.id == id }) else { return }
        var order = orders[index]
        change(&order)
        guard order != orders[index] else { return }
        orders[index] = order
        Self.persist(order)
    }

    /// Keeps the orders still waiting or able to change, and the newest few settled ones.
    private func prune() {
        let open = orders.filter { $0.entry == nil || $0.entry?.canStillChange == true }
        let settled = orders.filter { !($0.entry == nil || $0.entry?.canStillChange == true) }.sorted { $0.sentAt > $1.sentAt }.prefix(Self.settledKept)
        let keep = Set(open.map(\.id)).union(settled.map(\.id))
        if keep.count != orders.count { orders.removeAll { !keep.contains($0.id) } }
    }

    /// Whether the store keeps `order`: its result can still change (waiting, not confirmed, a growth seen on the chain,
    /// resting) and it isn't older than a day. A wallet-signed order is kept only until its receipt is read: it is the
    /// follow-up a return to the app decodes again (`PerplTrading.redecodeOnChainOrders`); nothing on Perpl's stream
    /// follows it after that.
    static func keepsRecord(_ order: PerplTrackedOrder, now: Date) -> Bool {
        guard now.timeIntervalSince(order.sentAt) < PerplPendingOrderStore.restingRetention else { return false }
        if order.isOnChain { return order.entry.map(PerplTracker.isUnconfirmed) ?? true }
        return order.entry == nil || order.entry?.canStillChange == true
    }

    private static func persist(_ order: PerplTrackedOrder) {
        guard let owner = order.owner else { return }
        var stored = PerplPendingOrderStore.all(owner: owner).filter { $0.id != order.id }
        if keepsRecord(order, now: Date()) { stored.append(order) }
        PerplPendingOrderStore.save(stored, owner: owner)
    }

    // MARK: Effects

    /// Carries out `effects` for `order`: its own notice (filed under the account it was sent for, and a banner only
    /// while that account is the one signed in), its one Activity row, and its trigger echoes. Everything else is
    /// `PerplTrading`'s (`perform`): the expected fill, the passkey refund, the noted close, the reload, the watcher.
    /// `positionEnded`: for a close sent from the position's Close sheet, whether Perpl's evidence says it ended the
    /// position (true), left part of it open (false), or can't say (nil: the 100% chip decides the words).
    func apply(_ effects: [PerplTrackerEffect], order: PerplTrackedOrder, boundOwner: Address?, positionEnded: Bool? = nil,
               perform: (PerplTrackerEffect) -> Void) {
        for effect in effects {
            switch effect {
            case .announce(let notice, let banner):
                let owner = order.owner
                #if DEBUG && targetEnvironment(simulator)
                if order.owner == nil, let debugNotice {
                    let words = Self.debugNoticeWords(notice, order, positionEnded: positionEnded)
                    debugNotice(words.title, words.body)
                }
                #endif
                // An order with no account posts nothing (only the DEBUG demo's have none).
                if order.owner == nil { break }
                let asset = order.asset
                let marketId = order.marketId
                let deliverBanner = banner && owner == boundOwner
                if order.isClose {
                    // A close names the POSITION it closed ("BTC-PERP long"), never the order's own side.
                    let position = PerpAlertText.positionName(asset: asset, side: order.closes ?? order.side.opposite)
                    Notifications.perpClose(title: Self.closeNoticeTitle(notice, order, positionEnded: positionEnded), position: position, perpId: marketId,
                                            owner: owner, deliver: deliverBanner)
                    break
                }
                let sideName = order.side == .long
                    ? tr(LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]"))
                    : tr(LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]"))
                Notifications.perpOrder(notice, side: sideName, market: "\(asset)-PERP", perpId: marketId, owner: owner, deliver: deliverBanner)
            case .recordActivity(let outcome):
                if case .onChain(let hash) = order.source {
                    // A wallet-signed order's row is its transaction's: the same hash replaces the row written at the receipt.
                    Self.record(outcome, order, kindName: Self.kindName(order), hash: hash, id: nil, owner: order.owner)
                } else {
                    Self.record(outcome, order, kindName: Self.kindName(order), hash: nil, id: order.id, owner: order.owner, positionEnded: positionEnded)
                }
            case .removeTriggerEcho(_, let echo):
                // This order's own echo only: another order's take-profit or stop-loss on that side is still live (GT-1).
                TriggerStore.remove(ids: [echo], owner: order.owner)
            case .noteAnnounced, .releaseExpectation, .refund, .voidUserClose, .reload, .wakeWatcher:
                perform(effect)
            }
        }
    }

    /// A close's notice title, from what Perpl reported: closed or partly closed (by `positionEnded`, else the 100% chip),
    /// a close order placed on the book, or not closed.
    static func closeNoticeTitle(_ notice: PerpOrderNotice, _ order: PerplTrackedOrder, positionEnded: Bool?) -> String {
        switch notice {
        case .filled:
            return closedWhole(order, positionEnded: positionEnded) ? tr("Closed \(order.asset)") : PerpOnChainCopy.partlyClosedTitle(order.asset)
        case .partlyFilled:
            return PerpOnChainCopy.partlyClosedTitle(order.asset)
        case .placed:
            return tr("Close order placed")
        case .notFilled, .failed:
            return PerplOutcomeText.notClosedHeadline
        case .submitted:
            return PerpOnChainCopy.closeTitle(order.asset)
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// The title and body `.announce` would post for `order` (the scripted demo's "Would notify" list): a close's names the
    /// position, an order's its side and market.
    static func debugNoticeWords(_ notice: PerpOrderNotice, _ order: PerplTrackedOrder, positionEnded: Bool?) -> (title: String, body: String) {
        if order.isClose {
            return (closeNoticeTitle(notice, order, positionEnded: positionEnded), PerpAlertText.positionName(asset: order.asset, side: order.closes ?? order.side.opposite))
        }
        let side = order.side == .long
            ? tr(LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]"))
            : tr(LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]"))
        return (notice.title, "\(side) \(order.asset)-PERP")
    }
    #endif

    /// A filled close ended the position: Perpl's evidence when there is some, else whether the 100% chip sent it.
    private static func closedWhole(_ order: PerplTrackedOrder, positionEnded: Bool?) -> Bool {
        if let positionEnded { return positionEnded }
        if case .close(let whole)? = order.purpose { return whole }
        return false
    }

    /// The order's type, as its Activity row names it.
    static func kindName(_ order: PerplTrackedOrder) -> String {
        order.isMarket
            ? tr(LocalizedStringResource("Market", comment: "Order type: a market order, which fills at once at the market price. [tight]"))
            : tr(LocalizedStringResource("Limit", comment: "Order type: rests at the price you set until it fills. [tight]"))
    }

    // MARK: Activity

    /// The id of an API order's one Activity row: the first 16 bytes of keccak("perpl-order:<account>:<rq>:<sent ms>").
    /// A reinstall can repeat a request id, never one at the same millisecond. Never the transaction Perpl forwarded it
    /// in: that is a batch shared with other orders and accounts.
    static func activityID(accountId: Int, rq: Int, sentAt: Date) -> UUID {
        let ms = Int((sentAt.timeIntervalSince1970 * 1000).rounded())
        let digest = Keccak.hash256(Data("perpl-order:\(accountId):\(rq):\(ms)".utf8)) // not localized: an identifier's seed
        let b = Array(digest.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The id of an add-margin request's one Activity row, sent over the trading connection: the first 16 bytes of
    /// keccak("perpl-margin:<account>:<rq>:<sent ms>"), so a later result rewrites the same row.
    static func marginActivityID(accountId: Int, rq: Int, sentAt: Date) -> UUID {
        let ms = Int((sentAt.timeIntervalSince1970 * 1000).rounded())
        let digest = Keccak.hash256(Data("perpl-margin:\(accountId):\(rq):\(ms)".utf8)) // not localized: an identifier's seed
        let b = Array(digest.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The order's one Activity row (`notify: false`: the order's own notice is posted on its own). API orders pass
    /// `hash: nil` and their `activityID`, so the row is written again under the same id as more is known; an on-chain
    /// order passes its hash. `usd` is only ever what filled, at the price it filled at (`volumeUSD`), or a growth on the
    /// chain only this order can explain: never the size ordered, never the mark. Nothing executed: no row of its own —
    /// only the rewrite of the row a growth on the chain wrote earlier (`PerplTracker.settleEntry` asks for it then), which
    /// says nothing filled and takes its volume back.
    ///
    /// A close sent from the position's Close sheet (`order.isClose`) is said of the position: only its title and
    /// subtitle differ (closed or partly closed — by `positionEnded`, else the 100% chip — a close order placed, or a
    /// close whose result isn't confirmed); its volume is the same as any order's.
    static func record(_ outcome: PerplOrderOutcome, _ order: PerplTrackedOrder, kindName: String, hash: Data?, id: UUID?, owner: Address?,
                       positionEnded: Bool? = nil) {
        let perp = "\(order.asset)-PERP"
        var title = order.side == .long ? tr("Long \(perp)") : tr("Short \(perp)")
        let c = order.textContext
        let ordered = PerplOutcomeText.amount(order.requestedSize, c)
        func price(_ value: Double) -> String { NumberStyle.number(value, maximumFractionDigits: order.priceDecimals) }
        var usd: Double?
        var fee: Double?
        var subtitle: String
        switch outcome {
        case .filled(let fill):
            let filled = PerplOutcomeText.amount(fill.size(lotDecimals: order.lotDecimals), c)
            if let p = fill.price(priceDecimals: order.priceDecimals), p > 0 {
                let at = price(p)
                subtitle = tr(LocalizedStringResource("\(filled) filled at \(at) · \(kindName)", comment: "A Perps Activity row's subtitle, under 'Long BTC-PERP': the order filled. The values: the amount filled (“0.001 BTC”), the average fill price, the order type ('Market' or 'Limit')."))
            } else {
                subtitle = tr(LocalizedStringResource("\(filled) filled · \(kindName)", comment: "A Perps Activity row's subtitle, under 'Long BTC-PERP': the order filled (price unknown). The values: the amount filled (“0.001 BTC”), the order type ('Market' or 'Limit')."))
            }
            usd = outcome.volumeUSD(priceDecimals: order.priceDecimals, lotDecimals: order.lotDecimals)
            fee = fill.feeUSD.flatMap { $0 > 0 ? $0 : nil }
        case .partlyFilled(let fill, _):
            let filled = PerplOutcomeText.amount(fill.size(lotDecimals: order.lotDecimals), c)
            let of = PerplOutcomeText.amount(Double(fill.requestedSizeRaw) / pow(10, Double(order.lotDecimals)), c)
            if let p = fill.price(priceDecimals: order.priceDecimals), p > 0 {
                let at = price(p)
                subtitle = tr(LocalizedStringResource("\(filled) of \(of) filled at \(at) · \(kindName)", comment: "A Perps Activity row's subtitle, under 'Long BTC-PERP': part of the order filled. The values: the amount filled (“0.001 BTC”), the amount ordered, the average fill price, the order type ('Market' or 'Limit')."))
            } else {
                subtitle = tr(LocalizedStringResource("\(filled) of \(of) filled · \(kindName)", comment: "A Perps Activity row's subtitle, under 'Long BTC-PERP': part of the order filled (price unknown). The values: the amount filled (“0.001 BTC”), the amount ordered, the order type ('Market' or 'Limit')."))
            }
            usd = outcome.volumeUSD(priceDecimals: order.priceDecimals, lotDecimals: order.lotDecimals)
            fee = fill.feeUSD.flatMap { $0 > 0 ? $0 : nil }
        case .resting:
            guard let limit = order.limitPrice, limit > 0 else { return }
            let at = price(limit)
            subtitle = tr(LocalizedStringResource("\(ordered) · limit placed at \(at)", comment: "A Perps Activity row's subtitle, under 'Long BTC-PERP': a limit order was placed on the order book (a past event: still true after it fills or is cancelled). The values: the amount ordered (“0.001 BTC”), the limit price."))
        case .observed(let growth):
            if growth.attributable, let p = growth.price, p > 0 {
                let grown = PerplOutcomeText.amount(growth.size, c)
                let at = price(p)
                subtitle = tr(LocalizedStringResource("\(grown) filled at about \(at) · \(kindName)", comment: "A Perps Activity row's subtitle, under 'Long BTC-PERP': Perpl's own report is missing, but the position on Monad grew by this much, which only this order can explain. The values: the amount (“0.001 BTC”), the price the growth implies, the order type ('Market' or 'Limit')."))
                usd = outcome.volumeUSD(priceDecimals: order.priceDecimals, lotDecimals: order.lotDecimals)
            } else {
                subtitle = unconfirmedSubtitle(ordered)
            }
        case .unconfirmed:
            subtitle = unconfirmedSubtitle(ordered)
        case .notFilled, .failed, .expired, .cancelled:
            // Replaces a row a growth on the chain wrote (same id): Perpl says none of it executed. No volume.
            subtitle = tr(LocalizedStringResource("\(ordered) · nothing filled · \(kindName)", comment: "A Perps Activity row's subtitle, under 'Long BTC-PERP': Perpl reported that none of the order executed, after the position on Monad had first looked like it grew from it. The values: the amount ordered (“0.001 BTC”), the order type ('Market' or 'Limit')."))
        case .armed, .triggered:
            return
        }
        if order.isClose { (title, subtitle) = closeWords(outcome, order, positionEnded: positionEnded, fallback: subtitle) }
        var row = ActivityRecord(kind: .perp, title: title, subtitle: subtitle, hash: hash, time: order.sentAt, section: "perps", usd: usd, feeUsd: fee)
        if let id { row.id = id }
        Activity.record(row, owner: owner, notify: false)
    }

    /// A close's row words (`record`): closed or partly closed with what closed at its price, a close order placed on the
    /// book, or the close's title over `fallback` (not confirmed, or nothing filled).
    private static func closeWords(_ outcome: PerplOrderOutcome, _ order: PerplTrackedOrder, positionEnded: Bool?, fallback: String) -> (String, String) {
        let c = order.textContext
        func price(_ value: Double) -> String { NumberStyle.number(value, maximumFractionDigits: order.priceDecimals) }
        switch outcome {
        case .filled(let fill):
            let closed = PerplOutcomeText.amount(fill.size(lotDecimals: order.lotDecimals), c)
            let title = closedWhole(order, positionEnded: positionEnded) ? tr("Closed \(order.asset)") : PerpOnChainCopy.partlyClosedTitle(order.asset)
            guard let p = fill.price(priceDecimals: order.priceDecimals), p > 0 else { return (title, closed) }
            return (title, PerpOnChainCopy.closedAt(closed, price: price(p)))
        case .partlyFilled(let fill, _):
            let closed = PerplOutcomeText.amount(fill.size(lotDecimals: order.lotDecimals), c)
            let whole = PerplOutcomeText.amount(Double(fill.requestedSizeRaw) / pow(10, Double(order.lotDecimals)), c)
            guard let p = fill.price(priceDecimals: order.priceDecimals), p > 0 else { return (PerpOnChainCopy.partlyClosedTitle(order.asset), closed) }
            return (PerpOnChainCopy.partlyClosedTitle(order.asset), PerpOnChainCopy.partlyClosedAt(closed, of: whole, price: price(p)))
        case .resting:
            let limit = tr(LocalizedStringResource("Limit", comment: "Order type: rests at the price you set until it fills. [tight]"))
            return (tr("Close order placed"), "\(PerplOutcomeText.amount(order.requestedSize, c)) · \(limit)")
        default:
            return (PerpOnChainCopy.closeTitle(order.asset), fallback)
        }
    }

    /// A wallet-signed order's row the moment its transaction confirms (GL-3), before its receipt is read: no volume,
    /// no notice. The decoded result replaces it (same hash).
    static func recordOnChainSent(_ order: PerplTrackedOrder, hash: Data) {
        let perp = "\(order.asset)-PERP"
        let title = order.side == .long ? tr("Long \(perp)") : tr("Short \(perp)")
        Activity.record(ActivityRecord(kind: .perp, title: title, subtitle: PerpOnChainCopy.orderSent, hash: hash, time: order.sentAt, section: "perps", usd: nil),
                        owner: order.owner, notify: false)
    }

    /// A wallet-signed order whose transaction confirmed but executed nothing: its row says so, with no volume (the order's
    /// own notice says it once).
    static func recordOnChainNotFilled(_ order: PerplTrackedOrder, hash: Data) {
        let perp = "\(order.asset)-PERP"
        let title = order.side == .long ? tr("Long \(perp)") : tr("Short \(perp)")
        PendingActivity.notFilled(hash, owner: order.owner)
        Activity.record(ActivityRecord(kind: .perp, title: title, subtitle: PerpOnChainCopy.nothingFilled, hash: hash, time: order.sentAt, section: "perps", usd: nil),
                        owner: order.owner, notify: false)
    }

    private static func unconfirmedSubtitle(_ ordered: String) -> String {
        tr(LocalizedStringResource("\(ordered) · result not confirmed — check Positions", comment: "A Perps Activity row's subtitle, under 'Long BTC-PERP': the order was sent, but its result couldn't be confirmed. The value: the amount ordered (“0.001 BTC”). Positions is a tab of the Perps screen."))
    }
}

/// The orders whose result can still change, per account, in UserDefaults ("perpl.pendingOrders.v2.<owner>"): what an
/// order that outlived its app (suspended, killed) is reconciled from on the next return. Public numbers only, never a
/// key or a token; at most 50 per account, none older than a day.
enum PerplPendingOrderStore {
    static let capacity = 50
    static let restingRetention: TimeInterval = 86_400

    private static func key(_ owner: Address) -> String { "perpl.pendingOrders.v2.\(owner.checksummed.lowercased())" } // not localized: a storage key

    static func all(owner: Address?) -> [PerplTrackedOrder] {
        guard let owner, let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([PerplTrackedOrder].self, from: data)) ?? []
    }

    static func save(_ orders: [PerplTrackedOrder], owner: Address) {
        let now = Date()
        let kept = Array(orders.filter { now.timeIntervalSince($0.sentAt) < restingRetention }.sorted { $0.sentAt > $1.sentAt }.prefix(capacity))
        if kept.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(owner))
        } else if let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: key(owner))
        }
    }

    static func remove(_ id: UUID, owner: Address) {
        let list = all(owner: owner)
        guard list.contains(where: { $0.id == id }) else { return }
        save(list.filter { $0.id != id }, owner: owner)
    }
}
