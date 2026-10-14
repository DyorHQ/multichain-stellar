import DyorKit
import Foundation
import Observation
import UserNotifications

/// One notification the app produced, kept in the in-app notification center. Every local (system) notification the
/// app delivers is also recorded here, so nothing is lost when the system banner is missed or permission is off.
struct AppNotification: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, Hashable, CaseIterable {
        case transaction, swap, perp, priceAlert, moments, system

        /// Tolerates values written by older builds (e.g. removed strategy kinds) so a legacy row never breaks decoding.
        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .system
        }

        var symbol: String {
            switch self {
            case .transaction: return "checkmark.circle"
            case .swap: return "arrow.left.arrow.right"
            case .perp: return "chart.line.uptrend.xyaxis"
            case .priceAlert: return "bell.badge"
            case .moments: return "camera.aperture"
            case .system: return "info.circle"
            }
        }

        /// The kind's name on the notification center's filter chips, in the app's language.
        var title: String {
            switch self {
            case .transaction: return tr(LocalizedStringResource("Transactions", comment: "A notification center filter [tight]"))
            case .swap: return tr(LocalizedStringResource("Swaps", comment: "A notification center filter [tight]"))
            case .perp: return tr(LocalizedStringResource("Perps", comment: "Perpetual futures [tight]"))
            case .priceAlert: return tr(LocalizedStringResource("Price alerts", comment: "A notification center filter [tight]"))
            case .moments: return tr(LocalizedStringResource("Moments", comment: "The Moments feature's name [tight]"))
            case .system: return "DyorHQ" // not localized: the app's name
            }
        }
    }

    /// Where a tap should take the user (DyorKit's `NotificationRoute`, which a tapped banner's `userInfo` carries too).
    typealias Route = NotificationRoute

    var id = UUID()
    let kind: Kind
    let title: String
    let body: String
    let time: Date
    var read: Bool
    let route: Route
    /// An optional id the route can open directly (a Moment id, …).
    let reference: String?

    init(kind: Kind, title: String, body: String, time: Date = Date(), read: Bool = false, route: Route = .none, reference: String? = nil) {
        self.kind = kind
        self.title = title
        self.body = body
        self.time = time
        self.read = read
        self.route = route
        self.reference = reference
    }
}

/// Per-wallet persistence of the notification center (UserDefaults; public text only).
enum NotificationStore {
    private static func key(_ owner: Address?) -> String { "notifications.v1." + (owner?.hex.lowercased() ?? "none") }
    private static let cap = 300

    static func all(owner: Address?) -> [AppNotification] {
        guard let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([AppNotification].self, from: data)) ?? []
    }

    /// Mirrors the center to the backend (installed by the app environment).
    nonisolated(unsafe) static var onChange: (([AppNotification], Address?) -> Void)?

    /// `mirror: false` for an account other than the one signed in, whose backend session isn't the app's: its copy
    /// catches up the next time its center changes while it is signed in.
    static func save(_ items: [AppNotification], owner: Address?, mirror: Bool = true) {
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(items.prefix(cap))), forKey: key(owner))
        if mirror { onChange?(items, owner) }
    }
}

/// The platform-wide notification system: one place every feature posts to. A post is recorded in the in-app center
/// (badge on Home, list with routes) and, when the user allowed it, delivered as a system notification (a banner in
/// the app, kept in Notification Center). There is no push server: everything is generated on-device while the app
/// runs — nothing arrives while it is suspended or closed — which is why the center keeps a durable record.
@Observable
@MainActor
final class NotificationHub {
    static let shared = NotificationHub()

    private(set) var items: [AppNotification] = []
    private(set) var owner: Address?
    /// The notification the user tapped in the list, for the router to open.
    var pendingRoute: AppNotification?

    var unreadCount: Int { items.lazy.filter { !$0.read }.count }

    /// Follows the signed-in wallet; each wallet has its own center.
    func bind(owner: Address?) {
        self.owner = owner
        items = NotificationStore.all(owner: owner)
    }

    /// Records the notification and delivers it as a system notification when `deliver` is true, the in-app master
    /// toggle is on, and OS permission is granted. The in-app center always keeps the record either way. `owner` is the
    /// account the action belongs to, when the caller knows it (`Activity.record`): an action that settles after the app
    /// moved to another account is filed in its own account's center, not the one on screen (RS-9).
    func post(_ notification: AppNotification, deliver: Bool = true, owner account: Address? = nil) {
        if let account, account != owner {
            var list = NotificationStore.all(owner: account)
            if let recent = list.first, recent.title == notification.title, recent.body == notification.body,
               notification.time.timeIntervalSince(recent.time) < 8 { return }
            list.insert(notification, at: 0)
            NotificationStore.save(list, owner: account, mirror: false)
            if deliver, Self.bannersEnabled { Self.deliverLocally(notification, account: account) }
            return
        }
        // Dedupe: a settled action recorded through two paths, or a retried transaction, can post twice. The activity
        // log already dedupes by tx hash, so the center must not double either — drop a repeat of the same
        // title+body that arrived within the last few seconds.
        if let recent = items.first, recent.title == notification.title, recent.body == notification.body,
           notification.time.timeIntervalSince(recent.time) < 8 { return }
        items.insert(notification, at: 0)
        if items.count > 300 { items = Array(items.prefix(300)) }
        NotificationStore.save(items, owner: owner)
        // The system BANNER respects the in-app "Enable Notifications" toggle (Profile → Notifications), not just OS
        // permission — so turning notifications off silences banners while the center still logs every event.
        if deliver, Self.bannersEnabled { Self.deliverLocally(notification, account: owner) }
    }

    /// The in-app notifications master toggle, persisted by AppSettings under this key (default on).
    private static var bannersEnabled: Bool { UserDefaults.standard.object(forKey: "settings.notifications") as? Bool ?? true }

    func post(kind: AppNotification.Kind, title: String, body: String, route: AppNotification.Route = .none, reference: String? = nil,
              deliver: Bool = true, owner account: Address? = nil) {
        post(AppNotification(kind: kind, title: title, body: body, route: route, reference: reference), deliver: deliver, owner: account)
    }

    /// The record `id` in the center on screen, if it is there.
    func item(_ id: UUID) -> AppNotification? { items.first { $0.id == id } }

    func markRead(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].read else { return }
        items[i].read = true
        NotificationStore.save(items, owner: owner)
    }

    /// Marks a tapped banner's record read in the center of `account`, the account it was recorded for. That is the
    /// center on screen, or one the app isn't showing (a banner from before an account switch, or a tap at a cold start
    /// that arrives before the center is bound): that account's stored center is updated, without the backend mirror,
    /// as `post` files a notification there. Nothing is written when the record isn't there (cleared, or never stored).
    func markRead(_ id: UUID, account: Address?) {
        guard account != owner else { return markRead(id) }
        var list = NotificationStore.all(owner: account)
        guard let i = list.firstIndex(where: { $0.id == id }), !list[i].read else { return }
        list[i].read = true
        NotificationStore.save(list, owner: account, mirror: false)
    }

    func markAllRead() {
        guard items.contains(where: { !$0.read }) else { return }
        for i in items.indices { items[i].read = true }
        NotificationStore.save(items, owner: owner)
    }

    func clear() {
        items = []
        NotificationStore.save(items, owner: owner)
    }

    /// Delivers a system notification now (no trigger). Silently no-ops unless the user granted permission. Its
    /// `userInfo` names the record, its route and `account`, the account whose center recorded it, so a tap on the banner
    /// marks the record read and opens its screen for that account only (`NotificationTap`, `NotificationRouteGate`).
    nonisolated static func deliverLocally(_ notification: AppNotification, account: Address?) {
        let title = notification.title, body = notification.body, id = notification.id.uuidString
        let userInfo = NotificationTap.userInfo(item: notification.id, route: notification.route, account: account)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = userInfo
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
