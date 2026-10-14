import Foundation

/// Where a notification takes the user when it is tapped, in the in-app center or as a banner. The raw values are
/// stored in the center's records and carried in a banner's `userInfo`, so they never change.
public enum NotificationRoute: String, Codable, Hashable, Sendable, CaseIterable {
    /// No screen of its own (a confirmation, say): a tap opens the app as it was.
    case none
    case home, trade, perps, launch, moments, portfolio

    /// Tolerates routes written by older builds (e.g. the removed strategy routes): they resolve to no route.
    public init(from decoder: Decoder) throws {
        self = NotificationRoute(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
    }
}

/// A tap on one of the app's banners, read back from the `userInfo` the app wrote when it delivered it (`userInfo(item:
/// route:account:)`). Only the app writes these values, but a banner delivered by an older build carries none and the
/// dictionary is untyped, so reading never fails: a route that is missing, unknown or of the wrong type opens Home. A
/// screen other than Home opens only for a banner that names its account, so the gate can refuse it for any other
/// account; one that names none, or an account that isn't an address, opens Home.
public struct NotificationTap: Hashable, Sendable {
    /// The `userInfo` keys. They name values in a banner only: the app stores nothing under them.
    public enum Key {
        public static let item = "dyorhq.notification.item"
        public static let route = "dyorhq.notification.route"
        public static let account = "dyorhq.notification.account"
    }

    /// The in-app center's record of the notification, to mark read; nil when the banner names none.
    public let item: UUID?
    /// The screen to open: `.none` opens the app as it was, as a tap on the record's row in the center does.
    public let route: NotificationRoute
    /// The account whose center recorded the notification; nil when the banner names none (the route is then Home).
    public let account: Address?

    public init(item: UUID?, route: NotificationRoute, account: Address?) {
        self.item = item
        self.account = account
        self.route = account == nil && route != .none ? .home : route
    }

    /// Reads a tapped banner's `userInfo`.
    public init(userInfo: [AnyHashable: Any]) {
        let item = (userInfo[Key.item] as? String).flatMap(UUID.init(uuidString:))
        let route = (userInfo[Key.route] as? String).flatMap(NotificationRoute.init(rawValue:)) ?? .home
        let account = (userInfo[Key.account] as? String).flatMap(Address.init)
        self.init(item: item, route: route, account: account)
    }

    /// The `userInfo` of a banner for the center's record `item`, which opens `route` and was recorded for `account` (nil
    /// for a record made while no account was signed in). Strings only, so the system can store it.
    public static func userInfo(item: UUID, route: NotificationRoute, account: Address?) -> [String: String] {
        var info = [Key.item: item.uuidString, Key.route: route.rawValue]
        if let account { info[Key.account] = account.hex }
        return info
    }
}

/// What to do with a tapped banner's route, given where the app is. It takes the Moment link gate's inputs and applies
/// its rules (`MomentLinkGate`): it waits while the session hasn't answered, or a review sheet, an approved action, or
/// a Face ID or passkey prompt is on screen (`busy`), and it is dropped under the update gate. Two rules are its own: a
/// route never waits through a sign-in (signed out, it is dropped, even behind a deletion screen), and a route for
/// another account than the one signed in is dropped, so a banner never opens another account's screen. Pure, so every
/// row is a test.
public enum NotificationRouteGate {
    public enum Decision: Hashable, Sendable {
        /// Keep the route; a later state change decides.
        case hold
        /// Forget it.
        case drop
        /// Open the screen now.
        case deliver
    }

    /// - Parameters:
    ///   - account: the account the banner names (`NotificationTap.account`).
    ///   - signedIn: the account signed in now (`Session.address`).
    ///   - The rest are `MomentLinkGate.decide`'s.
    public static func decide(phase: MomentLinkGate.Phase, updateRequired: Bool, deletionScreen: Bool, busy: Bool,
                              account: Address?, signedIn: Address?) -> Decision {
        if phase == .signedOut { return .drop }
        if phase == .signedIn, let account, account != signedIn { return .drop }
        switch MomentLinkGate.decide(phase: phase, updateRequired: updateRequired, deletionScreen: deletionScreen, busy: busy) {
        case .deliver: return .deliver
        case .drop: return .drop
        case .hold, .banner: return .hold
        }
    }

    /// Both gates at once, for what is waiting: a Moment link (`link`) and a tapped banner's `route` (nil when none
    /// waits; each decision is nil when nothing of its kind waits). When both may open now, only the one that arrived
    /// last does and the other is dropped, so the app never opens one screen and then jumps to another.
    public static func decide(link: Bool, route: NotificationTap?, routeArrivedLast: Bool, phase: MomentLinkGate.Phase,
                              updateRequired: Bool, deletionScreen: Bool, busy: Bool, signedIn: Address?)
        -> (link: MomentLinkGate.Decision?, route: Decision?) {
        let linkDecision = link ? MomentLinkGate.decide(phase: phase, updateRequired: updateRequired, deletionScreen: deletionScreen, busy: busy) : nil
        let routeDecision = route.map {
            decide(phase: phase, updateRequired: updateRequired, deletionScreen: deletionScreen, busy: busy, account: $0.account, signedIn: signedIn)
        }
        guard linkDecision == .deliver, routeDecision == .deliver else { return (linkDecision, routeDecision) }
        return routeArrivedLast ? (.drop, .deliver) : (.deliver, .drop)
    }
}
