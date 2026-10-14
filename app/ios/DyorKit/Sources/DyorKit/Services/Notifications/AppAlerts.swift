import Foundation

/* The rules of the app's alerts while it is open (build 17, N2): price alerts, Perps margin warnings, fills and
   closes, checked by one app-wide watcher on any screen. There is no push: nothing is checked while DyorHQ is closed or
   suspended, and the screens say so ("Alerts arrive while DyorHQ is open"). The app half is
   DyorHQ/Notifications/AlertCenter.swift. */

/// The user's notification switches (Profile › Notifications), and which alerts they let the watcher post.
public struct AlertPreferences: Hashable, Sendable {
    /// "Enable Notifications".
    public var notificationsEnabled: Bool
    /// "Swaps & Fills".
    public var fills: Bool
    /// "Price Alerts".
    public var priceAlerts: Bool
    /// "Perps Margin Warnings".
    public var marginWarnings: Bool

    public init(notificationsEnabled: Bool, fills: Bool, priceAlerts: Bool, marginWarnings: Bool) {
        self.notificationsEnabled = notificationsEnabled
        self.fills = fills
        self.priceAlerts = priceAlerts
        self.marginWarnings = marginWarnings
    }

    /// An order the watcher saw fill: posted only with both switches on, as the order screens' own notices are.
    public var postsFills: Bool { notificationsEnabled && fills }
    /// Price alerts are checked (and fire, and are removed) only with both switches on: off, they wait untouched.
    public var checksPriceAlerts: Bool { notificationsEnabled && priceAlerts }
    /// Margin warnings are evaluated only with both switches on.
    public var checksMargin: Bool { notificationsEnabled && marginWarnings }
}

/// When a price alert fires. An alert fires once: the app removes it when it fires (its stored form has no re-arm
/// setting), so the next crossing needs a new alert.
public enum PriceAlertCheck {
    /// The parts of a stored alert (the app's `PriceAlert`) a check reads.
    public struct Alert: Hashable, Sendable {
        public let id: UUID
        public let token: Address
        public let target: Double
        public let above: Bool

        public init(id: UUID, token: Address, target: Double, above: Bool) {
            self.id = id
            self.token = token
            self.target = target
            self.above = above
        }
    }

    /// Whether `price` has crossed the target: at or above it for an "above" alert, at or below it for a "below" one. A
    /// price that couldn't be read — none, zero, negative or not a finite number — never crosses, and neither does a
    /// target that isn't a positive finite number.
    public static func crossed(above: Bool, target: Double, price: Double?) -> Bool {
        guard let price, price.isFinite, price > 0, target.isFinite, target > 0 else { return false }
        return above ? price >= target : price <= target
    }

    /// The alerts that fire on `prices` (USD by token, read for `readFor`'s alerts). None when the account signed in now
    /// (`signedIn`) isn't the one they were read for: an account switched or signed out during the read isn't this
    /// read's to fire. `alreadyFired` are alerts this run already fired, which never fire twice even if the list still
    /// holds them.
    public static func firing(_ alerts: [Alert], prices: [Address: Double], readFor: Address, signedIn: Address?,
                              alreadyFired: Set<UUID> = []) -> [Alert] {
        guard signedIn == readFor else { return [] }
        return alerts.filter { !alreadyFired.contains($0.id) && crossed(above: $0.above, target: $0.target, price: prices[$0.token]) }
    }
}

/// The one alert loop's bookkeeping: which account it watches, and which run of it may still post. Binding the account
/// signed in starts a run; binding the same account again keeps it (never a second loop); another account, or none,
/// ends it, and only the newest run may post, for the account it was started for.
public struct AlertLoop: Sendable {
    /// What the app does after `bind`.
    public enum Change: Hashable, Sendable {
        /// The run already watching this account goes on.
        case keep
        /// No account: the run stops.
        case stop
        /// Stop the previous run, if any, and start this one.
        case start(run: Int)
    }

    /// How often the open positions are read for margin, fills and closes.
    public static let perpsInterval: TimeInterval = 15
    /// How often price alerts are checked.
    public static let priceInterval: TimeInterval = 30

    public private(set) var owner: Address?
    public private(set) var run = 0

    public init() {}

    public mutating func bind(_ owner: Address?) -> Change {
        guard owner != self.owner else { return .keep }
        self.owner = owner
        run += 1
        return owner == nil ? .stop : .start(run: run)
    }

    /// Whether `run`, started for `owner`, may still post: it is the newest run and its account is still the one bound.
    public func mayPost(run: Int, owner: Address) -> Bool {
        run == self.run && owner == self.owner
    }

    /// Whether a check last done at `last` is due at `now`: never done, `interval` passed, or the app just came back to
    /// the foreground (`woke`).
    public static func due(last: Date?, interval: TimeInterval, now: Date, woke: Bool) -> Bool {
        guard let last, !woke else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}
