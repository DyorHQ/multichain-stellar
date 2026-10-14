import BigInt
import DyorKit
import Foundation
import UserNotifications

/// On-device notifications for completed actions, triggered price alerts and Perps margin warnings, via the system
/// UserNotifications framework. There is no push server (that would need APNs): these are local notifications, posted by
/// the app while it runs — in the foreground, or in the few seconds before iOS suspends it. While the app is suspended or
/// closed nothing is noticed, so nothing is posted: alerts arrive while DyorHQ is open (`AlertCenter`).
@MainActor
enum Notifications {
    /// Installs the delegate that lets our notifications appear while the app is in the foreground, and hears a tap on
    /// one. Without it, iOS suppresses the banner whenever the app is open, which is exactly when these on-device
    /// notifications fire, so nothing ever shows on screen. Called from the app delegate's `didFinishLaunching`, before
    /// iOS hands over the tap that launched the app (a banner tapped while it was closed): a delegate set any later
    /// misses that tap. Calling it again changes nothing.
    static func configure() {
        let center = UNUserNotificationCenter.current()
        if center.delegate !== NotificationForegroundDelegate.shared { center.delegate = NotificationForegroundDelegate.shared }
    }

    /// A tapped banner: its record is marked read in the center of the account it was recorded for, and its screen
    /// waits on the router until RootView's gate lets it open (`NotificationRouteGate`): never behind a review sheet, a
    /// signing run or a Face ID prompt, and never for an account other than the one signed in.
    static func tapped(_ tap: NotificationTap) {
        if let item = tap.item { NotificationHub.shared.markRead(item, account: tap.account) }
        Router.shared.receive(tap)
    }

    /// Asks for permission (alert + sound). Called when the user turns notifications on in Settings, and once on
    /// sign-in so a default-on user is actually prompted (the Settings toggle only asks when it is flipped).
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Requests permission once if it has never been decided — used at sign-in so notifications work out of the box.
    static func requestAuthorizationIfUndetermined() async {
        if await authorizationStatus() == .notDetermined { _ = await requestAuthorization() }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The title and body are in the app's language when posted, and stay in it in the notification center.
    static func swapped(_ amountIn: BigUInt, _ tokenIn: Token, _ amountOut: BigUInt, _ tokenOut: Token) {
        let paid = "\(NumberStyle.units(amountIn, decimals: tokenIn.decimals, compact: true)) \(tokenIn.symbol)"
        let got = "\(NumberStyle.units(amountOut, decimals: tokenOut.decimals, compact: true)) \(tokenOut.symbol)"
        post(kind: .swap, title: tr("Swap complete"), body: tr("Swapped \(paid) → \(got)"), route: .trade)
    }

    /// A perp order the app sent or saw fill. `notice` says which: `PerpOrderNotice(acknowledged:)` for Perpl's
    /// acknowledgement of an order while the live outcome is off ("Order submitted" for a market order, "Order placed"
    /// for a limit order), `PerpOrderNotice(evidence:)` for what Perpl reported the order did (`PerplOrderTracker`), and
    /// `.filled` for a position read that saw the fill (the app-wide watcher, `AlertCenter`). With `perpId`, a tap opens
    /// that market. `side` is the side's name in the app's language ("Long"), followed by the market's name. `owner`: the
    /// account the order was sent for, when it may no longer be the one on screen (filed in its own center); `deliver`
    /// false files it without a banner (its sheet already shows it, or another account is signed in).
    static func perpOrder(_ notice: PerpOrderNotice, side: String, market: String, perpId: Int? = nil, owner: Address? = nil, deliver: Bool = true) {
        NotificationHub.shared.post(kind: .perp, title: notice.title, body: "\(side) \(market)", route: .perps,
                                    reference: perpId.map { PerpAlertText.reference(perpId: $0) }, deliver: deliver, owner: owner)
    }

    /// A close sent over the trading connection from the position's Close sheet, from what Perpl reported it did
    /// (`PerplOrderTracker`): `title` says what happened ("Closed BTC", "Not closed"), `position` names the POSITION it
    /// closed ("BTC-PERP long"), never the order's side. Filed under `owner`; `deliver` false files it without a banner.
    static func perpClose(title: String, position: String, perpId: Int, owner: Address?, deliver: Bool) {
        NotificationHub.shared.post(kind: .perp, title: title, body: position, route: .perps,
                                    reference: PerpAlertText.reference(perpId: perpId), deliver: deliver, owner: owner)
    }

    /// Margin sent over the trading connection whose result no sheet showed (`PerplTrading.addMargin`): refused, or not
    /// confirmed in time. An added margin's notice is its Activity row's own.
    static func perpMargin(title: String, body: String, perpId: Int, owner: Address?, deliver: Bool) {
        NotificationHub.shared.post(kind: .perp, title: title, body: body, route: .perps,
                                    reference: PerpAlertText.reference(perpId: perpId), deliver: deliver, owner: owner)
    }

    /// `label` is the action's name in the app's language.
    static func transactionConfirmed(_ label: String) {
        post(kind: .transaction, title: tr("Confirmed"), body: tr("\(label) confirmed on Monad."))
    }

    /// A completed cross-chain bridge — recorded in the notification center like a swap. The chains' names are never
    /// translated.
    static func bridge(amount: String, from: String, to: String) {
        post(kind: .swap, title: tr("Bridge complete"), body: tr("\(amount) bridged from \(from) to \(to)."), route: .home)
    }

    static func priceAlert(symbol: String, above: Bool, target: Double, price: Double) {
        let now = PriceFormat.usdPrice(price)
        let goal = PriceFormat.usdPrice(target)
        post(kind: .priceAlert, title: tr("Price alert: \(symbol)"),
             body: above ? tr("\(symbol) is now \(now) — above your \(goal) target.") : tr("\(symbol) is now \(now) — below your \(goal) target."),
             route: .home)
    }

    /// Records the notification in the in-app center and delivers it as a system notification (when permitted).
    static func post(kind: AppNotification.Kind, title: String, body: String, route: AppNotification.Route = .none, reference: String? = nil) {
        NotificationHub.shared.post(kind: kind, title: title, body: body, route: route, reference: reference)
    }
}

/// Presents DyorHQ's on-device notifications as banners while the app is open, and follows a tap on one. The app has
/// no push server, so every notification is generated while the user is in the app; without this delegate iOS would
/// only file them silently in Notification Center and never surface a banner.
final class NotificationForegroundDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationForegroundDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// A tap on the banner itself (not a dismissal) reads what the banner names (`NotificationTap`: a banner from an
    /// older build, or one that names nothing usable, opens Home) and hands it to the app (`Notifications.tapped`).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return completionHandler() }
        let tap = NotificationTap(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            Notifications.tapped(tap)
            completionHandler()
        }
    }
}
