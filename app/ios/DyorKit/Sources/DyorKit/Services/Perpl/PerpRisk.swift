import Foundation

/// How much of an open Perpl position's margin its maintenance requirement takes, and how far the mark is from its
/// liquidation price: what the app's Perps margin warnings are decided from (`PerpRiskLevel.next`), on any screen, while
/// the app is open.
///
/// Margin usage = maintenance margin needed / equity, where
/// - maintenance margin needed = entry price × size × the market's maintenance margin fraction: the fraction Perpl
///   reports (`getMarginFractions`, `PerpMarket.maintMarginFraction`) and the same requirement the liquidation price is
///   computed from (`PerplService.liquidationPrice`);
/// - equity = the margin posted + (mark − entry) × size for a long, (entry − mark) × size for a short + the position's
///   premium (the funding and settlement carried on it) — the margin plus `PerpPosition.unrealized`.
///
/// It is 100% exactly when the mark reaches the liquidation price. Equity under one AUSD unit (`equityFloor`) is past it
/// (`.infinity`): a rounding residue next to zero is no equity, not a reading of trillions of percent. It is unknown (nil)
/// when the maintenance fraction couldn't be read, or the position can't be valued: never a guess.
public enum PerpRisk {
    /// The smallest AUSD amount (6 decimals): equity under it is none.
    public static let equityFloor = 1e-6

    public static func marginUsage(side: PositionSide, entry: Double, size: Double, mark: Double, margin: Double, premium: Double,
                                   maintenanceFraction: Double?) -> Double? {
        guard let maintenanceFraction, maintenanceFraction > 0, maintenanceFraction.isFinite,
              size > 0, size.isFinite, entry > 0, entry.isFinite, mark > 0, mark.isFinite, margin.isFinite, premium.isFinite else { return nil }
        let needed = entry * size * maintenanceFraction
        let equity = margin + (side == .long ? mark - entry : entry - mark) * size + premium
        guard equity >= equityFloor else { return .infinity }
        return needed / equity
    }

    /// `marginUsage` of a position as `PerplService.positions` read it, at its own mark.
    public static func marginUsage(_ position: PerpPosition, maintenanceFraction: Double?) -> Double? {
        marginUsage(side: position.side, entry: position.entry, size: position.size, mark: position.mark, margin: position.margin,
                    premium: position.premium, maintenanceFraction: maintenanceFraction)
    }

    /// How far the mark is from the liquidation price, as a fraction of the mark: |mark − liquidation| / mark, and 0 once
    /// the mark has reached or passed it (a long's mark at or below it, a short's at or above). Nil without a liquidation
    /// price (an unknown maintenance fraction) or a mark.
    public static func liquidationDistance(side: PositionSide, mark: Double, liquidation: Double?) -> Double? {
        guard let liquidation, liquidation.isFinite, liquidation >= 0, mark > 0, mark.isFinite else { return nil }
        let room = side == .long ? mark - liquidation : liquidation - mark
        return max(0, room) / mark
    }
}

/// The margin warning a position is at. A notice goes out when a position's level rises (`PerpRiskLevel.next`), once per
/// level: a position that hovers at a threshold doesn't notify again until it has cleared the level's re-arm point.
public enum PerpRiskLevel: Int, Comparable, Hashable, Sendable, CaseIterable {
    /// Nothing to say.
    case normal
    /// The mark is within 10% of the liquidation price while margin usage is still under 80% (a position over about 2×
    /// gets this close before its usage does).
    case nearLiquidation
    /// Margin usage at 80% or more.
    case warning
    /// Margin usage at 90% or more: Perpl liquidates at 100%.
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Usage at which a warning starts, and below which it re-arms.
    public static let warningAt = 0.80
    public static let warningClearsBelow = 0.75
    /// Usage at which the critical level starts, and below which it re-arms.
    public static let criticalAt = 0.90
    public static let criticalClearsBelow = 0.85
    /// Distance (`PerpRisk.liquidationDistance`) at or under which the mark is near the liquidation price, and over which
    /// that re-arms.
    public static let nearLiquidationWithin = 0.10
    public static let nearLiquidationClearsAbove = 0.125

    /// The level after a reading, from the level the position was at, and the level to notify: only a rise is news.
    ///
    /// - critical: usage ≥ 90%; once there, it stays until usage drops below 85%.
    /// - warning: usage ≥ 80%; once there (or on the way down from critical), it stays until usage drops below 75%.
    /// - near liquidation: the mark within 10% of the liquidation price, when usage hasn't reached a warning first; once
    ///   there, it stays until the mark is more than 12.5% away. It is below a warning, so a position that warned on its
    ///   usage is not told again when its mark later comes within 10%.
    /// - normal otherwise.
    ///
    /// A reading that can't be valued (`usage` nil) changes nothing. `firstReading` is a position the watcher has no level
    /// for yet (the first read of the session, a position that just opened, or warnings just turned on): it is told only
    /// at a warning or critical — being near the liquidation price from the start (any position above about 5–10×) is
    /// what the ticket showed when it was opened, not news.
    public static func next(from current: PerpRiskLevel, usage: Double?, distance: Double?, firstReading: Bool = false)
        -> (level: PerpRiskLevel, notify: PerpRiskLevel?) {
        guard let usage, !usage.isNaN else { return (current, nil) }
        let near = distance.map { $0 <= nearLiquidationWithin } ?? false
        let stillNear = distance.map { $0 <= nearLiquidationClearsAbove } ?? false
        let level: PerpRiskLevel
        if usage >= criticalAt || (current == .critical && usage >= criticalClearsBelow) {
            level = .critical
        } else if usage >= warningAt || (current >= .warning && usage >= warningClearsBelow) {
            level = .warning
        } else if near || (current >= .nearLiquidation && stillNear) {
            level = .nearLiquidation
        } else {
            level = .normal
        }
        guard level > current else { return (level, nil) }
        if firstReading, level < .warning { return (level, nil) }
        return (level, level)
    }
}

/// A margin warning to post: the position as read, the level it rose to, and the reading behind it.
public struct PerpRiskNotice: Hashable, Sendable {
    public let position: PerpPosition
    public let level: PerpRiskLevel
    /// Margin usage, as a fraction (0.82 = 82%); `.infinity` once equity is gone.
    public let usage: Double
    public let distance: Double?
}

/// The margin warnings of one account's open positions, one level per position (`PerpRiskLevel.next`). A position is
/// known by its market and side: one that closes, or flips side, starts over. Kept in memory for the account the app
/// watches; a new account starts empty.
public struct PerpRiskWatch: Sendable {
    private var levels: [Int: (side: PositionSide, level: PerpRiskLevel)] = [:]

    public init() {}

    /// The level recorded for a market's position, if any.
    public func level(of perpId: Int) -> PerpRiskLevel? { levels[perpId]?.level }

    /// Reads `positions` (the account's open positions, as a complete read returned them) against each market's
    /// maintenance fraction, and returns the warnings that rose. A position missing from the read drops its level.
    public mutating func update(_ positions: [PerpPosition], maintenance: [Int: Double]) -> [PerpRiskNotice] {
        var next: [Int: (side: PositionSide, level: PerpRiskLevel)] = [:]
        var notices: [PerpRiskNotice] = []
        for position in positions {
            let known = levels[position.perpId].flatMap { $0.side == position.side ? $0.level : nil }
            let usage = PerpRisk.marginUsage(position, maintenanceFraction: maintenance[position.perpId])
            let distance = PerpRisk.liquidationDistance(side: position.side, mark: position.mark, liquidation: position.liquidation)
            guard let usage else {
                // Can't be valued now: keep what was known, and a position with no level stays a first reading.
                if let known { next[position.perpId] = (position.side, known) }
                continue
            }
            let step = PerpRiskLevel.next(from: known ?? .normal, usage: usage, distance: distance, firstReading: known == nil)
            next[position.perpId] = (position.side, step.level)
            if let level = step.notify { notices.append(PerpRiskNotice(position: position, level: level, usage: usage, distance: distance)) }
        }
        levels = next
        return notices
    }

    /// Forgets every level (warnings turned off): turned on again, each position is a first reading.
    public mutating func reset() { levels = [:] }
}

/// Fills and endings of one account's positions, between two complete reads. A position that opened or grew since the
/// last read filled an order (size is in base units: it moves on fills and closes, never with the mark); one that was
/// open at the last read and is gone from both the read and the account's own position bitmap ended. The first read
/// only records: what was already open isn't news.
public struct PerpPositionWatch: Sendable {
    public struct Changes: Hashable, Sendable {
        /// Positions that opened, grew, or flipped side: an order filled.
        public var filled: [PerpPosition] = []
        /// Positions that ended, as they were at the last read that held them.
        public var ended: [PerpPosition] = []
        /// By market, the size each `filled` position added: what it grew by, or its whole size when it is new or
        /// flipped side (base units).
        public var growth: [Int: Double] = [:]

        public init(filled: [PerpPosition] = [], ended: [PerpPosition] = [], growth: [Int: Double] = [:]) {
            self.filled = filled
            self.ended = ended
            self.growth = growth
        }
    }

    private var last: [Int: PerpPosition] = [:]
    private var primed = false

    public init() {}

    /// `fresh` is a complete read of the account's positions; `stillOpen` is the account's position bitmap
    /// (`PerpAccount.positionPerpIds`) at that read. A position the bitmap still marks open but the read left out stays
    /// known, so its ending is still seen later.
    public mutating func update(_ fresh: [PerpPosition], stillOpen: Set<Int>) -> Changes {
        var changes = Changes()
        let freshIds = Set(fresh.map(\.perpId))
        if primed {
            for position in fresh {
                guard let old = last[position.perpId] else {
                    changes.filled.append(position)
                    changes.growth[position.perpId] = position.size
                    continue
                }
                if old.side != position.side {
                    changes.filled.append(position)
                    changes.growth[position.perpId] = position.size
                } else if position.size > old.size + 1e-9 {
                    changes.filled.append(position)
                    changes.growth[position.perpId] = position.size - old.size
                }
            }
            for (perpId, old) in last.sorted(by: { $0.key < $1.key }) where !freshIds.contains(perpId) && !stillOpen.contains(perpId) {
                changes.ended.append(old)
            }
        }
        var next = Dictionary(fresh.map { ($0.perpId, $0) }, uniquingKeysWith: { first, _ in first })
        for (perpId, old) in last where !freshIds.contains(perpId) && stillOpen.contains(perpId) { next[perpId] = old }
        last = next
        primed = true
        return changes
    }
}

/// Orders the app sent that can grow a position, so the app-wide watcher neither races an order's own result nor
/// repeats it. One notice per fill: the order's own (`announced`), or the watcher's.
///
/// An order is expected from the moment it is sent until its result is in (`release`, or `announced` when it posted its
/// own fill notice for that much growth). While one is expected on a side of a market, a growth the watcher sees there
/// waits (`decide` → `.wait`) rather than racing the order's own notice, for at most two seconds past the order's
/// deadline. A growth the order's own notices explain (within the market's lot rounding, at most two minutes after them)
/// is quiet, and used up: the same growth seen again is a new fill. Anything else the watcher announces.
public struct PerpExpectedFills: Sendable {
    public enum Decision: Sendable, Equatable { case announce, quiet, wait }

    /// How long a fill the order announced explains a growth the watcher sees.
    public static let noteWindow: TimeInterval = 120
    /// How long past an expectation's deadline the watcher still waits for the order's own result.
    public static let waitGrace: TimeInterval = 2
    /// How long an expectation's market and side are remembered after it was released (a late fill can still note).
    static let memory: TimeInterval = 600

    struct Side: Hashable, Sendable { let perpId: Int; let side: PositionSide }
    struct Expectation: Sendable {
        let side: Side
        let growth: Double
        let until: Date
        let since: Date
        var open = true
    }
    struct Note: Sendable {
        let side: Side
        var size: Double
        let at: Date
    }

    private var expectations: [UUID: Expectation] = [:]
    private var notes: [Note] = []
    private var watcherNotices: [Side: Date] = [:]

    public init() {}

    /// At the send: `growth` from `PerplPositionEvidence.expectedGrowth` (an order that can grow nothing isn't expected).
    public mutating func expect(_ id: UUID, perpId: Int, side: PositionSide, growth: Double, until: Date) {
        expectations[id] = Expectation(side: Side(perpId: perpId, side: side), growth: growth, until: until, since: Date())
    }

    /// The order posted its own fill notice for `size` of growth on its side; its result is in.
    public mutating func announced(_ id: UUID, size: Double, at: Date) {
        guard let side = expectations[id]?.side else { return }
        expectations[id]?.open = false
        guard size > 0 else { return }
        notes.append(Note(side: side, size: size, at: at))
    }

    /// The order's result is in and it posts no fill notice (nothing filled, notifications off, resting, late).
    public mutating func release(_ id: UUID) {
        expectations[id]?.open = false
    }

    /// The watcher announced a fill on this side of the market.
    public mutating func watcherAnnounced(perpId: Int, side: PositionSide, at: Date) {
        watcherNotices[Side(perpId: perpId, side: side)] = at
    }

    /// The watcher announced a fill on this side of the market at or after `since`.
    public func watcherAnnounced(perpId: Int, side: PositionSide, since: Date) -> Bool {
        watcherNotices[Side(perpId: perpId, side: side)].map { $0 >= since } ?? false
    }

    /// What the watcher does with `growth` it saw on this side of the market: quiet when the orders' own notices explain
    /// it (it uses them up), wait while an order there is still expected (until two seconds past its deadline), else
    /// announce.
    public mutating func decide(perpId: Int, side: PositionSide, growth: Double, tolerance: Double, now: Date) -> Decision {
        let key = Side(perpId: perpId, side: side)
        notes.removeAll { now.timeIntervalSince($0.at) > Self.noteWindow }
        expectations = expectations.filter { now.timeIntervalSince($0.value.since) < Self.memory || $0.value.open && now < $0.value.until.addingTimeInterval(Self.waitGrace) }
        let explained = notes.filter { $0.side == key }.reduce(0) { $0 + $1.size }
        if explained > 0, growth <= explained + tolerance {
            var left = growth
            for index in notes.indices where notes[index].side == key && left > 0 {
                let used = min(notes[index].size, left)
                notes[index].size -= used
                left -= used
            }
            notes.removeAll { $0.size <= tolerance }
            return .quiet
        }
        if expectations.values.contains(where: { $0.side == key && $0.open && now < $0.until.addingTimeInterval(Self.waitGrace) }) { return .wait }
        return .announce
    }
}

/// What the watcher says about a position that ended (`PerpPositionWatch.Changes.ended`). The trading stream reports a
/// liquidation, a deleveraging (ADL) or an unwind, and a fired take-profit or stop-loss, the moment it happens, as a
/// protection notice (`PerplTrading`); the watcher never repeats it, so one ending gives one notice.
public enum PerpEndingNotice: Hashable, Sendable {
    /// Not yet: the stream is live and may still report how it ended.
    case wait
    /// Nothing to post: the user closed it from this app, or the stream already said how it ended.
    case quiet
    /// An order that closes the position (`PerpCloseOrder`) was resting on that market at the last read: it filled.
    case closeOrderFilled
    /// It closed some other way: on another device, or by the protocol while the stream wasn't live to say so.
    case closed

    /// How long a close sent from this app keeps its ending quiet.
    public static let userCloseWindow: TimeInterval = 600
    /// How long the watcher waits for a live stream to explain an ending before it posts one itself.
    public static let streamGrace: TimeInterval = 10

    /// - Parameters:
    ///   - endedAt: when the watcher first saw it gone.
    ///   - userClosedAt: when the user closed that position, or sent an order that closes it, from this app
    ///     (`PerpUserCloses.closedAt`).
    ///   - explainedByStream: the stream reported that market's position liquidated, deleveraged or unwound, or a TP/SL
    ///     on it triggered, recently (`PerplTrading.endingExplained`).
    ///   - streamLive: the trading stream is signed in with its positions list, so it would report a protocol ending.
    ///   - restingClose: an order that closes the position (`PerpCloseOrder`) rested on that market at the last read of
    ///     its orders.
    public static func decide(endedAt: Date, now: Date, userClosedAt: Date?, explainedByStream: Bool, streamLive: Bool,
                              restingClose: Bool) -> PerpEndingNotice {
        if let userClosedAt, now.timeIntervalSince(userClosedAt) < userCloseWindow { return .quiet }
        if explainedByStream { return .quiet }
        if streamLive, now.timeIntervalSince(endedAt) < streamGrace { return .wait }
        return restingClose ? .closeOrderFilled : .closed
    }
}

/// Which orders close a position. Perpl nets an order against the position on its market: a Short against a long (or a
/// Long against a short) closes it as far as the order's size goes, reduce-only or not, and one bigger than the position
/// turns it around. So an order closes a position when it is reduce-only or on the other side of it.
public enum PerpCloseOrder {
    /// The side of the position an order sent from this app closes, given the side the account holds on that market
    /// (`held`, nil for none): a reduce-only order closes the side opposite its own; any other order closes the position
    /// it is on the other side of. Nil for an order that opens a position or adds to one.
    public static func closes(orderSide: PositionSide, reduceOnly: Bool, held: PositionSide?) -> PositionSide? {
        (reduceOnly || held == orderSide.opposite) ? orderSide.opposite : nil
    }

    /// Whether a resting order closes the position held on its market: it is reduce-only, or a sell against a long, or
    /// a buy against a short.
    public static func closes(_ order: PerpOrder, held: PositionSide?) -> Bool {
        if order.reduceOnly { return true }
        guard let held else { return false }
        return order.side == (held == .long ? .sell : .buy)
    }

    /// The markets where a resting order closes the position held (`closes(_:held:)`), from one read of the account's
    /// orders and its positions.
    public static func restingCloseMarkets(orders: [PerpOrder], positions: [PerpPosition]) -> Set<Int> {
        let held = Dictionary(positions.map { ($0.perpId, $0.side) }, uniquingKeysWith: { first, _ in first })
        return Set(orders.filter { closes($0, held: held[$0.perpId]) }.map(\.perpId))
    }
}

/// The closes the user sent from this app, by market, with the side of the position each closes
/// (`PerpCloseOrder.closes`) and when. A noted close keeps that position's ending quiet
/// (`PerpEndingNotice.userCloseWindow`). A position on the other side of the same market is a new one (the order was
/// bigger than the position and turned it around), so its ending is still news.
public struct PerpUserCloses: Sendable {
    private var notes: [Int: (side: PositionSide, at: Date)] = [:]

    public init() {}

    /// The user sent an order at `at` that closes `perpId`'s position on `side`.
    public mutating func note(_ perpId: Int, closing side: PositionSide, at: Date) { notes[perpId] = (side, at) }

    /// The close noted for `perpId` never left the device.
    public mutating func forget(_ perpId: Int) { notes[perpId] = nil }

    /// When the user sent a close for `position` (its market and its side) from this app, if they did.
    public func closedAt(_ position: PerpPosition) -> Date? {
        notes[position.perpId].flatMap { $0.side == position.side ? $0.at : nil }
    }
}

/// The words of the app's Perps alerts, in the app's language when they are posted. A watched (watch-only) wallet's
/// alerts say what happened and never suggest an action it can't take from DyorHQ. Every title and body is one sentence
/// per side and level, so no English word is put into another language's sentence.
public enum PerpAlertText {
    /// "BTC-PERP long".
    public static func positionName(asset: String, side: PositionSide) -> String {
        side == .long
            ? L10n.string(LocalizedStringResource("\(asset)-PERP long", bundle: L10n.kit, comment: "A long position on a Perps market: “BTC-PERP long”."))
            : L10n.string(LocalizedStringResource("\(asset)-PERP short", bundle: L10n.kit, comment: "A short position on a Perps market: “BTC-PERP short”."))
    }

    /// The title and body of a margin warning. `canAct` is false for a watched wallet.
    public static func risk(_ notice: PerpRiskNotice, asset: String, canAct: Bool) -> (title: String, body: String) {
        let name = positionName(asset: asset, side: notice.position.side)
        let mark = PriceFormat.usdPrice(notice.position.mark)
        let liquidation = PriceFormat.usdPrice(notice.position.liquidation)
        let used = usageText(notice.usage)
        let act: String
        switch (notice.level, canAct) {
        case (_, false): act = L10n.tr("You're watching this wallet: DyorHQ can't change its positions.")
        case (.critical, true): act = L10n.tr("Add margin or reduce the position now.")
        default: act = L10n.tr("Add margin or reduce the position on Perps to stay clear of it.")
        }
        // All of its margin in use is a sentence of its own: "All" alone in the percent's place reads wrong in many languages.
        let all = usageIsAll(notice.usage)
        switch notice.level {
        case .critical:
            let body = all
                ? L10n.string(LocalizedStringResource("All of its margin is in use, and Perpl liquidates at 100%. Mark \(mark), liquidation \(liquidation). \(act)", bundle: L10n.kit, comment:
                    "A margin alert when all of a position's margin is in use. The values: the mark price, the liquidation price, then what to do, a sentence of its own."))
                : L10n.string(LocalizedStringResource("\(used) of its margin is in use, and Perpl liquidates at 100%. Mark \(mark), liquidation \(liquidation). \(act)", bundle: L10n.kit, comment:
                    "A margin alert. The values: the margin in use (“85%”), the mark price, the liquidation price, then what to do, a sentence of its own."))
            return (L10n.tr("Liquidation risk: \(name)"), body)
        case .warning:
            let body = all
                ? L10n.string(LocalizedStringResource("All of its margin is in use. Mark \(mark), liquidation \(liquidation). \(act)", bundle: L10n.kit, comment:
                    "A margin alert when all of a position's margin is in use. The values: the mark price, the liquidation price, then what to do, a sentence of its own."))
                : L10n.string(LocalizedStringResource("\(used) of its margin is in use. Mark \(mark), liquidation \(liquidation). \(act)", bundle: L10n.kit, comment:
                    "A margin alert. The values: the margin in use (“85%”), the mark price, the liquidation price, then what to do, a sentence of its own."))
            return (L10n.tr("Margin warning: \(name)"), body)
        case .nearLiquidation, .normal:
            return (L10n.tr("Near liquidation: \(name)"),
                    L10n.string(LocalizedStringResource("The mark, \(mark), is within 10% of the liquidation price, \(liquidation). \(act)", bundle: L10n.kit,
                        comment: "A margin alert. The values: the mark price, the liquidation price, then what to do, a sentence of its own.")))
        }
    }

    /// Whether a margin usage reads as all of it (`usageText`'s "All"): equity is gone, or the reading is past 1,000%.
    static func usageIsAll(_ usage: Double) -> Bool { !(usage.isFinite && usage < 10) }

    /// Margin usage as an alert says it: a whole percent, rounded down, or "All" once equity is gone or the reading is past
    /// 1,000% (equity next to nothing), so no reading, however large, can overflow the conversion to a whole number.
    public static func usageText(_ usage: Double) -> String {
        guard !usageIsAll(usage) else {
            return L10n.string(LocalizedStringResource("marginUsage.all", defaultValue: "All", bundle: L10n.kit, comment: "[tight] All of a position's margin is in use, where a percentage (“85%”) would stand."))
        }
        // not localized: a number and its percent sign
        return "\(Int((max(0, usage) * 100).rounded(.down)))%"
    }

    /// The title and body of an ending the watcher posts (`PerpEndingNotice`); nil for `.wait` and `.quiet`.
    public static func ending(_ notice: PerpEndingNotice, position: PerpPosition, asset: String) -> (title: String, body: String)? {
        let long = position.side == .long
        let size = "\(NumberStyle.number(position.size)) \(asset)"
        switch notice {
        case .wait, .quiet: return nil
        case .closeOrderFilled:
            return (L10n.string(LocalizedStringResource("Close order filled", bundle: L10n.kit, comment: "A notification's title: an order that closes a position (a close order) was filled (executed).")),
                    long ? L10n.tr("Your \(asset)-PERP long (\(size)) is closed.") : L10n.tr("Your \(asset)-PERP short (\(size)) is closed."))
        case .closed:
            return long
                ? (L10n.tr("\(asset)-PERP long closed"),
                   L10n.tr("Your \(size) long is no longer open, and it wasn't closed from this app. It may have hit a take-profit or stop-loss, been liquidated, or been closed on another device. Trade History shows how."))
                : (L10n.tr("\(asset)-PERP short closed"),
                   L10n.tr("Your \(size) short is no longer open, and it wasn't closed from this app. It may have hit a take-profit or stop-loss, been liquidated, or been closed on another device. Trade History shows how."))
        }
    }

    /// The reference a Perps alert's record carries, so a tap opens its market: "perp:<market id>".
    public static func reference(perpId: Int) -> String { "perp:\(perpId)" }

    /// The market a record's reference names (`reference(perpId:)`), or nil for any other reference.
    public static func market(reference: String?) -> Int? {
        guard let reference, reference.hasPrefix("perp:") else { return nil }
        let digits = reference.dropFirst(5)
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}
