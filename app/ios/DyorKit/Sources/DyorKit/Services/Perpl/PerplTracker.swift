import Foundation

/* An order the app sent, followed to what Perpl (or, failing its report, the chain) showed it did — whether or not its
   sheet stays open — and the decisions about it: when its notice posts and whether it may, what its one Activity row
   says, when a passkey charge is given back, which order the trade screen's status row shows, and whether Done clears
   the ticket. Pure and unit-tested: the app's `PerplOrderTracker` keeps the orders, `PerplTrading` waits on the stream,
   and both only carry out the effects returned here. */

/// One order sent from this device, as the tracker keeps it (persisted while its result can still change). Public
/// numbers only: never a key, a token or a signature.
public struct PerplTrackedOrder: Sendable, Equatable, Codable, Identifiable {
    public enum Source: Sendable, Equatable, Codable { case api(accountId: Int, rq: Int), onChain(hash: Data) }

    /// One take-profit or stop-loss sent with the order (`tr`-linked to it).
    public struct Child: Sendable, Equatable, Codable {
        public let kind: PerplTriggerKind
        /// Its request id, when it was written.
        public let rq: Int?
        public let price: Double
        /// Perpl answered its frame with code 0.
        public let accepted: Bool
        /// Its frame went out and was never answered: it may be live.
        public let unknown: Bool
        /// Never sent: Perpl never answered the entry, so its triggers stayed on the device (GL-1). Nothing about it can
        /// be Perpl's refusal.
        public let notSent: Bool
        /// The id of this device's echo of it (`TriggerStore`), when one was written: the only echo its order may remove.
        public let echoId: UUID?
        public var outcome: PerplOrderOutcome?
        /// Still on Perpl's live list after the entry executed nothing: it would act on a later position.
        public var armedWithoutPosition = false
        /// The entry executed nothing and a live list read afterwards no longer had it: evidence it went with the entry.
        public var checkedNotListed = false
        /// Its `outcome` was decided inside its own wait right after it was placed (not by a report minutes later).
        public var settledDuringFollow = false

        public init(kind: PerplTriggerKind, rq: Int?, price: Double, accepted: Bool, unknown: Bool, notSent: Bool = false, echoId: UUID? = nil,
                    outcome: PerplOrderOutcome? = nil) {
            self.kind = kind; self.rq = rq; self.price = price; self.accepted = accepted; self.unknown = unknown
            self.notSent = notSent; self.echoId = echoId; self.outcome = outcome
        }

        private enum CodingKeys: String, CodingKey {
            case kind, rq, price, accepted, unknown, notSent, echoId, outcome, armedWithoutPosition, checkedNotListed, settledDuringFollow
        }

        /// A record stored before a field existed still reads (the field takes its default).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(PerplTriggerKind.self, forKey: .kind)
            rq = try c.decodeIfPresent(Int.self, forKey: .rq)
            price = try c.decode(Double.self, forKey: .price)
            accepted = try c.decode(Bool.self, forKey: .accepted)
            unknown = try c.decode(Bool.self, forKey: .unknown)
            notSent = try c.decodeIfPresent(Bool.self, forKey: .notSent) ?? false
            echoId = try c.decodeIfPresent(UUID.self, forKey: .echoId)
            outcome = try c.decodeIfPresent(PerplOrderOutcome.self, forKey: .outcome)
            armedWithoutPosition = try c.decodeIfPresent(Bool.self, forKey: .armedWithoutPosition) ?? false
            checkedNotListed = try c.decodeIfPresent(Bool.self, forKey: .checkedNotListed) ?? false
            settledDuringFollow = try c.decodeIfPresent(Bool.self, forKey: .settledDuringFollow) ?? false
        }

        /// Perpl refused its frame (code ≠ 0): it was sent, answered, and isn't live.
        public var refused: Bool { !accepted && !unknown && !notSent }
    }

    /// The order's id, and its one Activity row's.
    public let id: UUID
    public let source: Source
    /// The account the order was sent for: its notice and row are filed there, whoever is signed in by then.
    public let owner: Address?
    public let sent: PerplSentRequest?
    public let marketId: Int
    public let asset: String
    public let priceDecimals: Int
    public let lotDecimals: Int
    public let side: PositionSide
    public let isMarket: Bool
    public let requestedSize: Double
    public let limitPrice: Double?
    public let reduceOnly: Bool
    /// The side of the position it closes (`PerpCloseOrder.closes`), nil when it opens or adds.
    public let closes: PositionSide?
    public let slippageBps: Int
    /// How much the order can grow a position on its side (`PerplPositionEvidence.expectedGrowth`); nil: nothing.
    public let expectedGrowth: Double?
    /// Perpl answered the entry with code 0.
    public let acknowledged: Bool
    public let sentAt: Date
    public let deadline: PerplOutcomeDeadline?
    /// The market's position before the order, read at `beforeReadAt` (nil: none was held then, or nothing was read).
    public let before: PerpPosition?
    public let beforeReadAt: Date?
    /// An order that can grow the same side rested on that market when it was sent (the chain's growth then can't be
    /// told apart from it).
    public let restingOnSide: Bool
    /// A wallet-signed order's Perpl account and the desc id its `execOrders` call carried: what finds its own request in
    /// its transaction's receipt (`PerplReceipt.orderOutcome`). Nil for an order sent over the trading connection.
    public var receiptKey: ReceiptKey?

    public struct ReceiptKey: Sendable, Equatable, Codable {
        public let accountId: Int
        /// The plan's desc id (`OrderDescIDs`, milliseconds); nil when the plan couldn't be read (the account's only
        /// request is read then).
        public let descId: UInt64?

        public init(accountId: Int, descId: UInt64?) { self.accountId = accountId; self.descId = descId }
    }

    /// Sent from the wallet as a transaction (`.onChain`): its result is read from the receipt, not from Perpl's stream.
    public var isOnChain: Bool { if case .onChain = source { return true }; return false }

    /// Why the order was sent, when it isn't the ticket's: `close` — the position's Close sheet sent it over the trading
    /// connection (`wholePosition`: the 100% chip, sent with the freshest size). Its result is said of the position, and
    /// its notice names the position. Otherwise it behaves as any reduce-only order: no expected growth, and a noted close
    /// voided when nothing executed.
    public enum Purpose: Sendable, Equatable, Codable {
        case close(wholePosition: Bool)
    }

    /// Nil: a ticket order (and every record stored before this existed).
    public var purpose: Purpose?

    /// The Close sheet sent it.
    public var isClose: Bool { if case .close? = purpose { return true }; return false }

    public var entry: PerplOrderOutcome?
    /// A failure Perpl reported that a later report may still replace (shown under the waiting status only).
    public var provisional: PerplOrderReason?
    public var takeProfit: Child?
    public var stopLoss: Child?
    /// The first result was a resting order: its later fills are the app-wide watcher's to announce.
    public var settledFirstAsResting = false
    public var announced = false
    public var refunded = false
    /// The filled size (raw) its Activity row was last written with.
    public var recordedFillRaw = 0
    public var presentedInSheet = false
    public var outcomeSeenInSheet = false
    public var bannerDismissed = false
    public var lastChangeAt: Date
    /// When the entry's result last changed (`settleEntry` only; a take-profit's or stop-loss's later change never
    /// counts): what a success on the trade screen's status row times out from. Nil in a record stored before it existed.
    public var entryChangedAt: Date?
    /// When the app-wide watcher started waiting for this order's own result (before its frames went out, or when its
    /// wallet transaction was about to be signed): the order's notice window, and the instant a notice the watcher
    /// gave counts from. Nil: `sentAt`.
    public var expectedSince: Date?

    public init(id: UUID, source: Source, owner: Address?, sent: PerplSentRequest?, marketId: Int, asset: String, priceDecimals: Int, lotDecimals: Int,
                side: PositionSide, isMarket: Bool, requestedSize: Double, limitPrice: Double?, reduceOnly: Bool, closes: PositionSide?,
                slippageBps: Int, expectedGrowth: Double?, acknowledged: Bool, sentAt: Date, deadline: PerplOutcomeDeadline?,
                before: PerpPosition?, beforeReadAt: Date?, restingOnSide: Bool, takeProfit: Child? = nil, stopLoss: Child? = nil,
                receiptKey: ReceiptKey? = nil) {
        self.id = id; self.source = source; self.owner = owner; self.sent = sent; self.marketId = marketId; self.asset = asset
        self.priceDecimals = priceDecimals; self.lotDecimals = lotDecimals; self.side = side; self.isMarket = isMarket
        self.requestedSize = requestedSize; self.limitPrice = limitPrice; self.reduceOnly = reduceOnly; self.closes = closes
        self.slippageBps = slippageBps; self.expectedGrowth = expectedGrowth; self.acknowledged = acknowledged
        self.sentAt = sentAt; self.deadline = deadline; self.before = before; self.beforeReadAt = beforeReadAt
        self.restingOnSide = restingOnSide; self.takeProfit = takeProfit; self.stopLoss = stopLoss; self.receiptKey = receiptKey
        self.lastChangeAt = sentAt
    }

    /// What its result is said with (`PerplOutcomeText`).
    public var textContext: PerplOutcomeText.Context {
        PerplOutcomeText.Context(asset: asset, priceDecimals: priceDecimals, lotDecimals: lotDecimals, requestedSize: requestedSize,
                                 limitPrice: limitPrice, isMarket: isMarket, reducesPosition: reduceOnly || closes != nil,
                                 slippageBps: slippageBps, acknowledged: acknowledged)
    }

    /// The order's result isn't in yet (nothing decided, or only "not confirmed").
    public var isAwaiting: Bool { entry == nil }

    public func child(_ kind: PerplTriggerKind) -> Child? { kind == .takeProfit ? takeProfit : stopLoss }

    /// A take-profit or stop-loss asked for with the order isn't known to be live: Perpl refused it, never answered it,
    /// or it was never sent. Its warning shows from the moment the order is followed, whatever the entry is doing, and a
    /// success with it never leaves the trade screen's status row by itself.
    public var hasTriggerWarning: Bool {
        PerplTriggerKind.allCases.contains { child($0).map { !$0.accepted } ?? false }
    }

    /// When the order's notice window and the watcher's notices count from.
    public var noticeSince: Date { expectedSince ?? sentAt }

    mutating func setChild(_ kind: PerplTriggerKind, _ child: Child) {
        if kind == .takeProfit { takeProfit = child } else { stopLoss = child }
    }
}

/// What the app does when an order's result comes in. Each is carried out once, in order.
public enum PerplTrackerEffect: Sendable, Equatable {
    /// The order's one Activity row (same id, or same hash), written again with what is known now.
    case recordActivity(PerplOrderOutcome)
    /// The order's own notice.
    case announce(PerpOrderNotice, deliverBanner: Bool)
    /// `PerpExpectedFills.announced`: the order announced this much growth on its side.
    case noteAnnounced(growth: Double)
    case releaseExpectation, refund, voidUserClose, reload, wakeWatcher
    /// `TriggerStore.remove(ids:)`: this order's own echo of a take-profit or stop-loss that will never be live — never
    /// another order's echo of the same kind on that side (both stay live on Perpl, GT-1).
    case removeTriggerEcho(PerplTriggerKind, echo: UUID)
}

public enum PerplTracker {
    /// How long after the send a fill the watcher hasn't announced yet is still the order's own to announce.
    public static let lateNoticeWindow: TimeInterval = 120
    /// How long a success stays on the trade screen's status row.
    public static let successBannerSeconds: TimeInterval = 8

    /// Applies a newly decided entry outcome once: updates the order and returns its effects. The entry settles the
    /// moment it is decided, whatever its take-profit and stop-loss are doing. A result that can no longer change (filled,
    /// partly filled with nothing left on the book, nothing executed) is final: no later report replaces it. Its notice
    /// posts once, on its first result other than "not confirmed" or a growth on the chain it can't claim: a fill
    /// (within its window and not already announced by the watcher, and never a resting order's later fill), a
    /// nothing-executed or a refusal; never a cancel the user made. A growth it announced that Perpl then says executed
    /// nothing gets a second notice, and its row is written again without volume. Its Activity row carries a fill (and is
    /// written again as more fills), a resting order, or a growth on the chain. A result that executed nothing gives the
    /// passkey charge back and voids the noted close, once. Its take-profit and stop-loss echoes stay until their own
    /// result, or a live list read after it, says they are gone (`settleChild`, `markCheckedNotListed`).
    public static func settleEntry(_ order: inout PerplTrackedOrder, _ outcome: PerplOrderOutcome, now: Date,
                                   notify: Bool, appActive: Bool, watcherAnnouncedSinceSent: Bool) -> [PerplTrackerEffect] {
        guard order.entry != outcome else { return [] }
        let previous = order.entry
        // Final: a lagging history or a late report never overwrites it (a refund, a voided close, a second row).
        if let previous, !previous.canStillChange { return [] }
        order.entry = outcome
        order.provisional = nil
        order.lastChangeAt = now
        order.entryChangedAt = now
        // Seen where it shows: in its sheet, or (closed) on the trade screen's status row.
        order.outcomeSeenInSheet = order.presentedInSheet
        var effects: [PerplTrackerEffect] = []

        let previousObserved = previous.map(isObserved) ?? false
        // A growth on the chain is not Perpl's word: what Perpl says next is the order's first real result.
        let decidedBefore = previous.map { !isUnconfirmed($0) && !isObserved($0) } ?? false
        if isUnconfirmed(outcome) {
            effects.append(.releaseExpectation)
        } else if !decidedBefore, !order.announced {
            effects += notice(&order, outcome, now: now, notify: notify, appActive: appActive, watcherAnnouncedSinceSent: watcherAnnouncedSinceSent)
            if isResting(outcome) { order.settledFirstAsResting = true }
        } else if !decidedBefore, previousObserved, outcome.executedNothing {
            // "Order filled" went out for a growth Perpl now says this order never made: said again, corrected (a cancel
            // included: the user was told it filled).
            if notify { effects.append(.announce(PerpOrderNotice(evidence: outcome) ?? .notFilled, deliverBanner: !(order.presentedInSheet && appActive))) }
            effects.append(.releaseExpectation)
        }

        switch outcome {
        case .filled(let fill), .partlyFilled(let fill, _):
            if fill.filledSizeRaw > order.recordedFillRaw {
                order.recordedFillRaw = fill.filledSizeRaw
                effects.append(.recordActivity(outcome))
            }
        case .resting, .observed:
            if order.recordedFillRaw == 0 { effects.append(.recordActivity(outcome)) }
        case .notFilled, .failed, .expired, .cancelled:
            // The row a growth on the chain wrote (with its volume) is written again: nothing filled, no volume.
            if previousObserved, order.recordedFillRaw == 0 { effects.append(.recordActivity(outcome)) }
        default:
            break
        }

        if outcome.executedNothing, !order.refunded {
            order.refunded = true
            effects.append(.refund)
            // A close that never happened: its ending is news again (only while the noted close still stands).
            if order.closes != nil, now.timeIntervalSince(order.sentAt) < PerpEndingNotice.userCloseWindow { effects.append(.voidUserClose) }
        }
        effects.append(.reload)
        effects.append(.wakeWatcher)
        return effects
    }

    /// The order's own notice for its first result, and what the expected fill becomes.
    private static func notice(_ order: inout PerplTrackedOrder, _ outcome: PerplOrderOutcome, now: Date, notify: Bool, appActive: Bool,
                               watcherAnnouncedSinceSent: Bool) -> [PerplTrackerEffect] {
        let deliverBanner = !(order.presentedInSheet && appActive)
        switch outcome {
        case .observed(let growth) where !growth.attributable:
            // Another order (resting, tracked, or read too long before) may have grown that side: never "Order filled"
            // for it, and the watcher's note isn't spent on it. The watcher announces the growth itself.
            return [.releaseExpectation]
        case .filled, .partlyFilled, .observed:
            let deadline = order.deadline?.wallClock ?? order.noticeSince.addingTimeInterval(PerplTimeouts.outcomeWallClock)
            let inWindow = now <= deadline.addingTimeInterval(PerpExpectedFills.waitGrace)
            let lateButOurs = now.timeIntervalSince(order.noticeSince) <= lateNoticeWindow
            // Whichever window: a fill the watcher already announced on that side is never announced twice.
            guard notify, inWindow || lateButOurs, !watcherAnnouncedSinceSent, !order.settledFirstAsResting,
                  let notice = PerpOrderNotice(evidence: outcome) else {
                return [.releaseExpectation]
            }
            order.announced = true
            if let growth = filledGrowth(order, outcome), growth > 0 {
                return [.announce(notice, deliverBanner: deliverBanner), .noteAnnounced(growth: growth)]
            }
            return [.announce(notice, deliverBanner: deliverBanner), .releaseExpectation]
        case .notFilled, .expired, .failed:
            guard notify, let notice = PerpOrderNotice(evidence: outcome) else { return [.releaseExpectation] }
            order.announced = true
            return [.announce(notice, deliverBanner: deliverBanner), .releaseExpectation]
        case .cancelled, .resting, .armed, .triggered, .unconfirmed:
            return [.releaseExpectation]
        }
    }

    /// The growth on the order's side that its filled size explains: the expected growth recomputed from the size that
    /// filled (a flip grows by what is left after the position it turned around); nil for an order that grows nothing.
    static func filledGrowth(_ order: PerplTrackedOrder, _ outcome: PerplOrderOutcome) -> Double? {
        guard let expected = order.expectedGrowth, expected > 0 else { return nil }
        if case .observed(let growth) = outcome { return growth.size }
        guard let fill = outcome.fill else { return nil }
        let filled = fill.size(lotDecimals: order.lotDecimals)
        // What the order netted against before it could grow its side (0 unless it turned a position around).
        let netted = max(0, order.requestedSize - expected)
        let grown = filled - netted
        return grown > 0 ? grown : nil
    }

    /// A take-profit or stop-loss of the order settled. `duringFollow`: decided inside its own wait right after it was
    /// placed (the sheet may then say "triggered at once" or "not placed"); a later report is said neutrally. Its echo on
    /// this device — its own, never another order's — goes when its own result says it will never be live: cancelled,
    /// refused or expired. Never on "armed", whatever the entry did: only a live list read afterwards may say it went
    /// with an entry that executed nothing (`markCheckedNotListed`).
    public static func settleChild(_ order: inout PerplTrackedOrder, kind: PerplTriggerKind, _ outcome: PerplOrderOutcome, now: Date,
                                   duringFollow: Bool = false) -> [PerplTrackerEffect] {
        guard var child = order.child(kind), child.outcome != outcome else { return [] }
        child.outcome = outcome
        child.settledDuringFollow = duringFollow
        order.setChild(kind, child)
        order.lastChangeAt = now
        switch outcome {
        case .cancelled, .failed, .expired:
            return removeEcho(child)
        default:
            return []
        }
    }

    /// A take-profit or stop-loss of an order that executed nothing is still on Perpl's live list.
    public static func markArmedWithoutPosition(_ order: inout PerplTrackedOrder, kind: PerplTriggerKind, now: Date) {
        guard var child = order.child(kind), !child.armedWithoutPosition else { return }
        child.armedWithoutPosition = true
        order.setChild(kind, child)
        order.lastChangeAt = now
    }

    /// The entry executed nothing, and a live list read afterwards (one that can tell this trigger's request) no longer
    /// has this take-profit or stop-loss: it went with the entry. Its own echo goes, once.
    public static func markCheckedNotListed(_ order: inout PerplTrackedOrder, kind: PerplTriggerKind, now: Date) -> [PerplTrackerEffect] {
        guard order.entry?.executedNothing == true, var child = order.child(kind), !child.checkedNotListed, !child.armedWithoutPosition else { return [] }
        child.checkedNotListed = true
        order.setChild(kind, child)
        order.lastChangeAt = now
        return removeEcho(child)
    }

    /// The child's own echo, when it has one (one never sent, or refused, never had one).
    private static func removeEcho(_ child: PerplTrackedOrder.Child) -> [PerplTrackerEffect] {
        guard let echo = child.echoId, !child.notSent else { return [] }
        return [.removeTriggerEcho(child.kind, echo: echo)]
    }

    /// The order the trade screen's status row shows for `marketId`: the newest one not shown in its sheet that is still
    /// waiting, or settled and not yet seen there. A success leaves `successBannerSeconds` after its ENTRY settled (a
    /// take-profit or stop-loss changing later never brings it back); a success with a take-profit or stop-loss that
    /// isn't known to be live, a warning or a failure stays until dismissed.
    public static func bannerOrder(_ orders: [PerplTrackedOrder], marketId: Int, now: Date) -> PerplTrackedOrder? {
        orders
            .filter { order in
                guard order.marketId == marketId, !order.presentedInSheet, !order.bannerDismissed else { return false }
                guard let entry = order.entry else { return true }
                if order.outcomeSeenInSheet { return false }
                if entry.tone == .success, !order.hasTriggerWarning {
                    return now.timeIntervalSince(order.entryChangedAt ?? order.lastChangeAt) < successBannerSeconds
                }
                return true
            }
            .max { $0.sentAt < $1.sentAt }
    }

    /// Whether the chain's growth may still be read as this order's (resolve step (c)): only while its own result could
    /// still be arriving — up to `window` past its deadline — and never for an order read back from the store (orders
    /// sent before a relaunch are invisible to the "another order on that side" check, so a growth can't be pinned on it).
    public static func mayReadChainGrowth(_ order: PerplTrackedOrder, now: Date, loadedFromDisk: Bool, window: TimeInterval) -> Bool {
        guard !loadedFromDisk else { return false }
        let deadline = order.deadline?.wallClock ?? order.sentAt
        return now.timeIntervalSince(order.sentAt) <= deadline.timeIntervalSince(order.sentAt) + window
    }

    /// Whether Done clears the ticket: yes for anything that filled, rests, grew the position or may have executed
    /// (still waiting or not confirmed: a blind resend could double it); no when the order provably executed nothing,
    /// so it can be sent again as it is.
    public static func clearsTicket(_ outcome: PerplOrderOutcome?) -> Bool {
        guard let outcome else { return true }
        return !outcome.executedNothing
    }

    /// Not confirmed: Perpl's result didn't arrive in time.
    public static func isUnconfirmed(_ outcome: PerplOrderOutcome) -> Bool {
        if case .unconfirmed = outcome { return true }
        return false
    }

    /// Resting on the book, in whole or in part.
    public static func isResting(_ outcome: PerplOrderOutcome) -> Bool {
        switch outcome {
        case .resting, .partlyFilled(_, rest: .resting): return true
        default: return false
        }
    }

    /// Only a growth seen on the chain: Perpl's own report never came.
    public static func isObserved(_ outcome: PerplOrderOutcome) -> Bool {
        if case .observed = outcome { return true }
        return false
    }
}
