import XCTest
@testable import DyorKit

/// The app's local notifications (build 17, N1): what a perp order's notice says, the delegate installed at launch, and
/// a tapped banner's screen, read back from its `userInfo` and opened only through the link gate.
final class LocalNotificationTests: XCTestCase {
    private let a = Address(literal: "0x1111111111111111111111111111111111111111")
    private let b = Address(literal: "0x2222222222222222222222222222222222222222")

    /// The app's sources, or a skip when this checkout has no app.
    private func appSource(_ path: String) throws -> String {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        let app = ios.appendingPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every Swift file of the app, by path relative to `ios/DyorHQ`.
    private func appSources() throws -> [(path: String, text: String)] {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() }
        let app = ios.appendingPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map { file in
            (String(file.path.dropFirst(app.path.count + 1)), try String(contentsOf: file, encoding: .utf8))
        }
    }

    /// A DyorKit source file, by path relative to `Sources/DyorKit`.
    private func kitSource(_ path: String) throws -> String {
        var kit = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { kit.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit
        return try String(contentsOf: kit.appendingPathComponent("Sources/DyorKit").appendingPathComponent(path), encoding: .utf8)
    }

    /// `text` with every run of whitespace as one space: the checks pin the code, not its indentation.
    private func squeeze(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The text of the function that starts at `signature` in `text`, up to its closing brace at the indentation it
    /// opened at.
    private func function(_ signature: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), signature)
        let line = text[..<start.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let indent = String(line.prefix { $0 == " " })
        let end = try XCTUnwrap(text.range(of: "\n" + indent + "}\n", range: start.upperBound..<text.endIndex), signature)
        return String(text[start.lowerBound..<end.upperBound])
    }

    // MARK: - Perp order notices

    /// Perpl acknowledging a market order is not a fill: it says "Order submitted". A limit order says "Order placed".
    /// Only a position read says "Order filled".
    func testAnAcknowledgedOrderIsNeverFilled() {
        XCTAssertEqual(PerpOrderNotice(acknowledged: .market), .submitted)
        XCTAssertEqual(PerpOrderNotice(acknowledged: .market).title, "Order submitted")
        XCTAssertEqual(PerpOrderNotice(acknowledged: .limit), .placed)
        XCTAssertEqual(PerpOrderNotice(acknowledged: .limit).title, "Order placed")
        XCTAssertEqual(PerpOrderNotice.filled.title, "Order filled")
        for kind in [OrderKind.market, .limit] {
            XCTAssertNotEqual(PerpOrderNotice(acknowledged: kind), .filled, "\(kind)")
        }
    }

    /// The app posts an order's notice from evidence or, with the live outcome off, from the acknowledgement: the
    /// order's own notice comes from what Perpl reported it did (`PerpOrderNotice(evidence:)`, posted by the order
    /// tracker, filed under the account the order was sent for and a banner only when it isn't on screen), the switch-off
    /// sheet's from the order's kind at acknowledgement, and `.filled` from the app-wide watcher's position read
    /// (`AlertCenter.checkPerps`, build 17 N2). The old `filled:` flag (which made a market order say "Order filled" at
    /// acknowledgement) is gone, and an acknowledgement never becomes a fill.
    func testTheAppPostsTheNoticeFromEvidenceOrAck() throws {
        let notifications = try appSource("Wallet/Notifications.swift")
        XCTAssertTrue(notifications.contains("static func perpOrder(_ notice: PerpOrderNotice, side: String, market: String, perpId: Int? = nil, owner: Address? = nil, deliver: Bool = true) {"))
        XCTAssertTrue(squeeze(notifications).contains("post(kind: .perp, title: notice.title, body: \"\\(side) \\(market)\", route: .perps, reference: perpId.map { PerpAlertText.reference(perpId: $0) }, deliver: deliver, owner: owner)"))
        XCTAssertFalse(notifications.contains("\"Order filled\""), "the titles live in PerpOrderNotice")

        let trade = try appSource("Perps/PerpTradeView.swift")
        let legacy = try function("private func placeLegacy(approval: MeraSession.StepUp? = nil) async {", in: trade)
        XCTAssertTrue(legacy.contains("Notifications.perpOrder(PerpOrderNotice(acknowledged: input.kind), side:"), "the switch-off sheet")
        let live = try function("private func place(approval: MeraSession.StepUp? = nil) async {", in: trade)
        XCTAssertFalse(live.contains("Notifications."), "the live sheet posts nothing at the acknowledgement")
        let tracker = try appSource("Wallet/PerplOrderTracker.swift")
        XCTAssertTrue(squeeze(tracker).contains("Notifications.perpOrder(notice, side: sideName, market: \"\\(asset)-PERP\", perpId: marketId, owner: owner, deliver: deliverBanner)"))
        XCTAssertTrue(squeeze(tracker).contains("let deliverBanner = banner && owner == boundOwner"), "a banner only for the account signed in")
        let fills = try appSource("Notifications/AlertCenter.swift")
        let detect = try function("private func checkPerps(", in: fills)
        XCTAssertTrue(detect.contains("Notifications.perpOrder(.filled, side:"), "the fill notice comes from the watcher's position read")

        for (path, text) in try appSources() {
            XCTAssertFalse(text.contains("filled: input.kind == .market"), path)
            XCTAssertFalse(text.contains("filled: true"), path)
            let calls = text.components(separatedBy: "Notifications.perpOrder(").dropFirst()
            for call in calls {
                let notice = call.prefix { $0 != "," }
                XCTAssertTrue((notice == "PerpOrderNotice(acknowledged: input.kind)" && path == "Perps/PerpTradeView.swift")
                              || (notice == "notice" && path == "Wallet/PerplOrderTracker.swift")
                              || (notice == ".filled" && path == "Notifications/AlertCenter.swift"),
                              "\(path): perpOrder(\(notice), …)")
            }
        }
        XCTAssertEqual(try appSource("Perps/PerpTradeView.swift").components(separatedBy: "Notifications.perpOrder(").count - 1, 1, "the switch-off sheet only")
        XCTAssertEqual(tracker.components(separatedBy: "Notifications.perpOrder(").count - 1, 1)
        // A close from the position's Close sheet names the POSITION (p4 spec #16); margin over the trading connection
        // posts from PerplTrading only, when no sheet shows its result.
        XCTAssertTrue(notifications.contains("static func perpClose(title: String, position: String, perpId: Int, owner: Address?, deliver: Bool) {"))
        XCTAssertTrue(notifications.contains("static func perpMargin(title: String, body: String, perpId: Int, owner: Address?, deliver: Bool) {"))
        for (path, text) in try appSources() {
            let close = text.components(separatedBy: "Notifications.perpClose(").count - 1
            XCTAssertEqual(close, path == "Wallet/PerplOrderTracker.swift" ? 1 : 0, path)
            if text.contains("Notifications.perpMargin(") { XCTAssertEqual(path, "Wallet/PerplTrading.swift") }
        }
        let announce = try XCTUnwrap(tracker.range(of: "case .announce(let notice, let banner):"))
        let announceBody = String(tracker[announce.upperBound...].prefix(1800))
        let ownerGuard = try XCTUnwrap(announceBody.range(of: "if order.owner == nil { break }"))
        let firstPost = try XCTUnwrap(announceBody.range(of: "Notifications."))
        XCTAssertLessThan(ownerGuard.lowerBound, firstPost.lowerBound, "an order with no account posts nothing")
        XCTAssertTrue(squeeze(announceBody).contains("let position = PerpAlertText.positionName(asset: asset, side: order.closes ?? order.side.opposite)"))
        // The notice from evidence: never from an acknowledgement, never for what didn't fill.
        let evidence = try kitSource("Services/Notifications/PerpOrderNotice.swift")
        XCTAssertTrue(squeeze(evidence).contains("case .filled, .observed: self = .filled case .partlyFilled: self = .partlyFilled case .resting: self = .placed case .notFilled, .expired: self = .notFilled case .failed: self = .failed case .cancelled, .armed, .triggered, .unconfirmed: return nil"))
    }

    // MARK: - The delegate, at launch

    /// The notification delegate is installed in the app delegate's `didFinishLaunching`, before iOS hands over the tap
    /// that launched the app, and nowhere else: not in RootView's `.task`, which runs too late for a cold start.
    /// Banners keep showing while the app is open.
    func testTheDelegateIsSetAtLaunch() throws {
        let app = try appSource("App/DyorHQApp.swift")
        let delegate = try XCTUnwrap(app.range(of: "final class AppDelegate: NSObject, UIApplicationDelegate {"))
        let launch = try function("func application(_ application: UIApplication,\n                     didFinishLaunchingWithOptions", in: String(app[delegate.upperBound...]))
        XCTAssertTrue(launch.contains("Notifications.configure()"))
        XCTAssertTrue(launch.contains("return true"))

        let root = try appSource("App/RootView.swift")
        XCTAssertFalse(root.contains("Notifications.configure()"))
        XCTAssertTrue(squeeze(root).contains(".task { session.start(); settings.appearance.apply() }"))

        let notifications = try appSource("Wallet/Notifications.swift")
        let configure = squeeze(try function("static func configure() {", in: notifications))
        XCTAssertTrue(configure.contains("if center.delegate !== NotificationForegroundDelegate.shared { center.delegate = NotificationForegroundDelegate.shared }"),
                      "set once; a second call changes nothing")
        let willPresent = try function("func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent", in: notifications)
        XCTAssertTrue(willPresent.contains("completionHandler([.banner, .list, .sound])"))

        for (path, text) in try appSources() {
            XCTAssertEqual(text.components(separatedBy: "Notifications.configure()").count - 1, path == "App/DyorHQApp.swift" ? 1 : 0, path)
            let delegates = text.components(separatedBy: "delegate = NotificationForegroundDelegate.shared").count - 1
            XCTAssertEqual(delegates, path == "Wallet/Notifications.swift" ? 1 : 0, path)
        }
    }

    // MARK: - A banner's userInfo

    /// Every route survives a banner: what the app writes reads back as the same record, screen and account.
    func testEveryRouteReadsBack() {
        XCTAssertEqual(NotificationRoute.allCases.map(\.rawValue), ["none", "home", "trade", "perps", "launch", "moments", "portfolio"],
                       "stored in the center and carried by banners: the raw values never change")
        for route in NotificationRoute.allCases {
            let item = UUID()
            let info = NotificationTap.userInfo(item: item, route: route, account: a)
            XCTAssertEqual(info, [NotificationTap.Key.item: item.uuidString, NotificationTap.Key.route: route.rawValue, NotificationTap.Key.account: a.hex])
            // The system hands it back as `[AnyHashable: Any]`.
            let tap = NotificationTap(userInfo: info as [AnyHashable: Any])
            XCTAssertEqual(tap, NotificationTap(item: item, route: route, account: a))
            XCTAssertEqual(tap.item, item)
            XCTAssertEqual(tap.route, route)
            XCTAssertEqual(tap.account, a)
        }
        // A checksummed or upper-case address is the same account.
        let mixed = NotificationTap(userInfo: [NotificationTap.Key.route: "perps", NotificationTap.Key.account: a.checksummed])
        XCTAssertEqual(mixed.account, a)
        XCTAssertEqual(mixed.route, .perps)
    }

    /// A banner from an older build carries nothing, and one whose values are missing, unknown or of the wrong type
    /// opens Home; reading it never fails.
    func testAMissingOrUnknownRouteOpensHome() {
        let item = UUID()
        let empty = NotificationTap(userInfo: [:])
        XCTAssertNil(empty.item)
        XCTAssertNil(empty.account)
        XCTAssertEqual(empty.route, .home)

        for route in ["strategy", "copyTrading", "", "Perps", "PERPS", " perps", "perps ", "0"] {
            let tap = NotificationTap(userInfo: [NotificationTap.Key.item: item.uuidString, NotificationTap.Key.route: route, NotificationTap.Key.account: a.hex])
            XCTAssertEqual(tap.route, .home, route)
            XCTAssertEqual(tap.item, item, route)
            XCTAssertEqual(tap.account, a, route)
        }
        // The route missing, the rest there.
        XCTAssertEqual(NotificationTap(userInfo: [NotificationTap.Key.item: item.uuidString, NotificationTap.Key.account: a.hex]).route, .home)

        // Values of the wrong type are as good as missing.
        let wrong: [AnyHashable: Any] = [NotificationTap.Key.item: item, NotificationTap.Key.route: 3, NotificationTap.Key.account: a.data]
        XCTAssertEqual(NotificationTap(userInfo: wrong), NotificationTap(item: nil, route: .home, account: nil))
        let wrongRoute: [AnyHashable: Any] = [NotificationTap.Key.item: item.uuidString, NotificationTap.Key.route: ["perps"], NotificationTap.Key.account: a.hex]
        XCTAssertEqual(NotificationTap(userInfo: wrongRoute), NotificationTap(item: item, route: .home, account: a))
        // Keys that aren't strings are not ours.
        let otherKeys: [AnyHashable: Any] = [1: "perps", NotificationTap.Key.route as NSString: 2]
        XCTAssertEqual(NotificationTap(userInfo: otherKeys).route, .home)

        // A malformed record id is no record; a malformed account is no account.
        let malformed = NotificationTap(userInfo: [NotificationTap.Key.item: "not-a-uuid", NotificationTap.Key.route: "trade", NotificationTap.Key.account: "0x1234"])
        XCTAssertNil(malformed.item)
        XCTAssertNil(malformed.account)
        XCTAssertEqual(malformed.route, .home, "a screen other than Home needs an account the gate can check")
    }

    /// A banner that names no account (a record made while signed out) opens Home, whatever screen it names, so the
    /// gate never opens an unchecked account's screen; one that names no screen (`.none`) opens the app as it was.
    func testABannerWithoutAnAccountOpensHome() {
        for route in NotificationRoute.allCases {
            let info = NotificationTap.userInfo(item: UUID(), route: route, account: nil)
            XCTAssertNil(info[NotificationTap.Key.account])
            let tap = NotificationTap(userInfo: info)
            XCTAssertNil(tap.account)
            XCTAssertEqual(tap.route, route == .none ? .none : .home, "\(route)")
        }
        XCTAssertEqual(NotificationTap(item: nil, route: .portfolio, account: nil).route, .home)
        XCTAssertEqual(NotificationTap(item: nil, route: .none, account: a).route, .none)
    }

    /// A banner recorded for another account reads back as that account, and the gate drops it.
    func testABannerForAnotherAccountIsDropped() {
        let tap = NotificationTap(userInfo: NotificationTap.userInfo(item: UUID(), route: .portfolio, account: b))
        XCTAssertEqual(tap.account, b)
        XCTAssertEqual(tap.route, .portfolio)
        XCTAssertEqual(NotificationRouteGate.decide(phase: .signedIn, updateRequired: false, deletionScreen: false, busy: false, account: tap.account, signedIn: a), .drop)
        XCTAssertEqual(NotificationRouteGate.decide(phase: .signedIn, updateRequired: false, deletionScreen: false, busy: false, account: tap.account, signedIn: b), .deliver)
        XCTAssertEqual(NotificationRouteGate.decide(phase: .signedIn, updateRequired: false, deletionScreen: false, busy: false, account: tap.account, signedIn: nil), .drop)
    }

    /// The center's records keep decoding routes written by older builds (the removed strategy routes) as no route.
    func testStoredRoutesDecode() throws {
        let decoded = try JSONDecoder().decode([NotificationRoute].self, from: Data(#"["perps","strategy","none","portfolio"]"#.utf8))
        XCTAssertEqual(decoded, [.perps, .none, .none, .portfolio])
        XCTAssertEqual(try JSONEncoder().encode([NotificationRoute.trade]), Data(#"["trade"]"#.utf8))
    }

    // MARK: - The gate

    /// Every combination of the gate's inputs. A banner's screen opens only signed in, as the account the banner names
    /// (or a banner that names none, whose screen is Home), outside the update gate, with nothing busy; it waits through
    /// a cold start and anything busy (a review sheet, a signing run, an App Lock or passkey prompt); everything else
    /// drops it.
    func testTheGateTable() {
        let phases: [MomentLinkGate.Phase] = [.loading, .signedOut, .signedIn]
        var rows = 0
        for phase in phases {
            for updateRequired in [false, true] {
                for deletionScreen in [false, true] {
                    for busy in [false, true] {
                        for account in [nil, a, b] {
                            for signedIn in [nil, a] {
                                rows += 1
                                let expected: NotificationRouteGate.Decision
                                switch phase {
                                case .loading: expected = .hold
                                case .signedOut: expected = .drop
                                case .signedIn:
                                    if updateRequired || (account != nil && account != signedIn) { expected = .drop } else if busy { expected = .hold } else { expected = .deliver }
                                }
                                let decision = NotificationRouteGate.decide(phase: phase, updateRequired: updateRequired, deletionScreen: deletionScreen,
                                                                            busy: busy, account: account, signedIn: signedIn)
                                let row = "\(phase) update:\(updateRequired) deletion:\(deletionScreen) busy:\(busy) account:\(account?.hex ?? "nil") signedIn:\(signedIn?.hex ?? "nil")"
                                XCTAssertEqual(decision, expected, row)

                                // The Moment link gate's rules hold for a banner too: never delivered where a link isn't.
                                let link = MomentLinkGate.decide(phase: phase, updateRequired: updateRequired, deletionScreen: deletionScreen, busy: busy)
                                if decision == .deliver { XCTAssertEqual(link, .deliver, row) }
                                if link == .drop { XCTAssertEqual(decision, .drop, row) }
                                if phase == .signedIn, account == nil || account == signedIn {
                                    XCTAssertEqual(decision, link == .deliver ? .deliver : link == .drop ? .drop : .hold, row)
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows, 144)
    }

    /// The G3 cases by name.
    func testTheRiskCases() {
        typealias G = NotificationRouteGate
        // A tap during signing (a review sheet up, a run sending, an App Lock or passkey prompt): it waits, then opens.
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: false, deletionScreen: false, busy: true, account: a, signedIn: a), .hold)
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: false, deletionScreen: false, busy: false, account: a, signedIn: a), .deliver)
        // A tap that waited through a signing run, then a sign-out: dropped, and still dropped once someone signs in.
        XCTAssertEqual(G.decide(phase: .signedOut, updateRequired: false, deletionScreen: false, busy: false, account: a, signedIn: nil), .drop)
        // A tap after sign-out, even behind the account-deleted screen: dropped, never kept for the next sign-in.
        XCTAssertEqual(G.decide(phase: .signedOut, updateRequired: false, deletionScreen: true, busy: false, account: a, signedIn: nil), .drop)
        // A tap at a cold start waits for the session; it then opens for its account, or is dropped for another.
        XCTAssertEqual(G.decide(phase: .loading, updateRequired: false, deletionScreen: false, busy: false, account: a, signedIn: nil), .hold)
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: false, deletionScreen: false, busy: false, account: a, signedIn: b), .drop)
        // Behind the update gate nothing that signs is reachable: dropped.
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: true, deletionScreen: false, busy: false, account: a, signedIn: a), .drop)
    }

    /// A banner's screen and a Moment link waiting together: each gate decides its own, and when both may open now only
    /// the one that arrived last opens, so the app never opens one screen and jumps to another.
    func testABannerAndAMomentLinkTogether() {
        func both(routeArrivedLast: Bool, phase: MomentLinkGate.Phase = .signedIn, busy: Bool = false, account: Address?, signedIn: Address?)
            -> (link: MomentLinkGate.Decision?, route: NotificationRouteGate.Decision?) {
            NotificationRouteGate.decide(link: true, route: NotificationTap(item: nil, route: .perps, account: account), routeArrivedLast: routeArrivedLast,
                                         phase: phase, updateRequired: false, deletionScreen: false, busy: busy, signedIn: signedIn)
        }
        var d = both(routeArrivedLast: true, account: a, signedIn: a)
        XCTAssertEqual(d.link, .drop); XCTAssertEqual(d.route, .deliver)
        d = both(routeArrivedLast: false, account: a, signedIn: a)
        XCTAssertEqual(d.link, .deliver); XCTAssertEqual(d.route, .drop)
        // Both wait behind a sheet.
        d = both(routeArrivedLast: true, busy: true, account: a, signedIn: a)
        XCTAssertEqual(d.link, .hold); XCTAssertEqual(d.route, .hold)
        // The banner is another account's: the link opens whichever came last.
        d = both(routeArrivedLast: true, account: b, signedIn: a)
        XCTAssertEqual(d.link, .deliver); XCTAssertEqual(d.route, .drop)
        // Signed out: the link waits with its banner for the sign-in, the banner's screen is dropped.
        d = both(routeArrivedLast: true, phase: .signedOut, account: a, signedIn: nil)
        XCTAssertEqual(d.link, .banner); XCTAssertEqual(d.route, .drop)

        // Only what waits is decided, as its own gate decides it.
        let phases: [MomentLinkGate.Phase] = [.loading, .signedOut, .signedIn]
        for phase in phases {
            for updateRequired in [false, true] {
                for deletionScreen in [false, true] {
                    for busy in [false, true] {
                        for account in [nil, a, b] {
                            for last in [false, true] {
                                let tap = NotificationTap(item: nil, route: .trade, account: account)
                                let link = MomentLinkGate.decide(phase: phase, updateRequired: updateRequired, deletionScreen: deletionScreen, busy: busy)
                                let route = NotificationRouteGate.decide(phase: phase, updateRequired: updateRequired, deletionScreen: deletionScreen, busy: busy,
                                                                         account: account, signedIn: a)
                                let none = NotificationRouteGate.decide(link: false, route: nil, routeArrivedLast: last, phase: phase, updateRequired: updateRequired,
                                                                        deletionScreen: deletionScreen, busy: busy, signedIn: a)
                                XCTAssertNil(none.link); XCTAssertNil(none.route)
                                let linkOnly = NotificationRouteGate.decide(link: true, route: nil, routeArrivedLast: last, phase: phase, updateRequired: updateRequired,
                                                                            deletionScreen: deletionScreen, busy: busy, signedIn: a)
                                XCTAssertEqual(linkOnly.link, link); XCTAssertNil(linkOnly.route)
                                let routeOnly = NotificationRouteGate.decide(link: false, route: tap, routeArrivedLast: last, phase: phase, updateRequired: updateRequired,
                                                                             deletionScreen: deletionScreen, busy: busy, signedIn: a)
                                XCTAssertNil(routeOnly.link); XCTAssertEqual(routeOnly.route, route)
                                let together = NotificationRouteGate.decide(link: true, route: tap, routeArrivedLast: last, phase: phase, updateRequired: updateRequired,
                                                                            deletionScreen: deletionScreen, busy: busy, signedIn: a)
                                XCTAssertFalse(together.link == .deliver && together.route == .deliver, "never both")
                                if link == .deliver, route == .deliver {
                                    XCTAssertEqual(together.link, last ? .drop : .deliver); XCTAssertEqual(together.route, last ? .deliver : .drop)
                                } else {
                                    XCTAssertEqual(together.link, link); XCTAssertEqual(together.route, route)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - The app's wiring

    /// Every banner carries its record, its route and its account; a tap marks the record read and leaves its screen
    /// waiting on the router (the latest tap wins); RootView's one gate opens it, held by everything that holds a Moment
    /// link and by an App Lock or passkey prompt; the screen opened is the one a row of the center opens.
    func testTheAppRoutesATapThroughTheGate() throws {
        let hub = squeeze(try appSource("Notifications/NotificationHub.swift"))
        let deliver = try function("nonisolated static func deliverLocally(", in: try appSource("Notifications/NotificationHub.swift"))
        XCTAssertTrue(deliver.contains("let userInfo = NotificationTap.userInfo(item: notification.id, route: notification.route, account: account)"))
        XCTAssertTrue(deliver.contains("content.userInfo = userInfo"))
        XCTAssertTrue(deliver.contains("UNNotificationRequest(identifier: id, content: content, trigger: nil)"))
        XCTAssertTrue(deliver.contains("id = notification.id.uuidString"))
        // Filed in another account's center, the banner names that account; filed in the center on screen, its owner.
        XCTAssertTrue(hub.contains("NotificationStore.save(list, owner: account, mirror: false) if deliver, Self.bannersEnabled { Self.deliverLocally(notification, account: account) }"))
        XCTAssertTrue(hub.contains("NotificationStore.save(items, owner: owner) // The system BANNER"))
        XCTAssertTrue(hub.contains("if deliver, Self.bannersEnabled { Self.deliverLocally(notification, account: owner) }"))
        XCTAssertEqual(hub.components(separatedBy: "Self.deliverLocally(").count - 1, 2)
        XCTAssertTrue(hub.contains("func markRead(_ id: UUID, account: Address?) { guard account != owner else { return markRead(id) }"))

        let notifications = try appSource("Wallet/Notifications.swift")
        let didReceive = squeeze(try function("func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive", in: notifications))
        XCTAssertTrue(didReceive.contains("guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return completionHandler() }"))
        XCTAssertTrue(didReceive.contains("let tap = NotificationTap(userInfo: response.notification.request.content.userInfo)"))
        XCTAssertTrue(didReceive.contains("Task { @MainActor in Notifications.tapped(tap) completionHandler() }"))
        let tapped = squeeze(try function("static func tapped(_ tap: NotificationTap) {", in: notifications))
        XCTAssertTrue(tapped.contains("if let item = tap.item { NotificationHub.shared.markRead(item, account: tap.account) }"))
        XCTAssertTrue(tapped.contains("Router.shared.receive(tap)"))
        XCTAssertFalse(tapped.contains("open("), "nothing navigates outside the gate")

        let app = try appSource("App/DyorHQApp.swift")
        XCTAssertTrue(app.contains("@State private var router = Router.shared"), "the router the delegate hands taps to is the app's")

        let router = try appSource("App/Router.swift")
        XCTAssertTrue(router.contains("static let shared = Router()"))
        let receive = squeeze(try function("func receive(_ tap: NotificationTap) {", in: router))
        XCTAssertTrue(receive.contains("pendingNotificationRoute = tap.route == .none ? nil : tap notificationRouteArrivedLast = true"), "the latest tap replaces a waiting one")
        let handle = squeeze(try function("func handle(_ url: URL) {", in: router))
        XCTAssertTrue(handle.contains("pendingLink = link notificationRouteArrivedLast = false"))
        let deliverRoute = squeeze(try function("func deliverPendingNotificationRoute() {", in: router))
        XCTAssertTrue(deliverRoute.contains("guard let tap = pendingNotificationRoute else { return } pendingNotificationRoute = nil menuOpen = false open(route: tap.route, reference: tap.item.flatMap { NotificationHub.shared.item($0)?.reference })"),
                      "cleared before it opens: it opens once, at the market its record names")
        XCTAssertTrue(squeeze(router).contains("func open(_ notification: AppNotification) { open(route: notification.route, reference: notification.reference) }"), "the center's mapping")
        let open = try function("func open(route: NotificationRoute, reference: String? = nil) {", in: router)
        XCTAssertTrue(open.contains("guard route != .none else { return }"))
        XCTAssertFalse(open.contains("default"), "exhaustive: a new route is a compile error here")
        for route in NotificationRoute.allCases { XCTAssertTrue(open.contains("case .\(route.rawValue):"), "\(route)") }
        // A Perps notice opens the market its record names (`PerpAlertText.reference`); any other reference opens Perps.
        XCTAssertTrue(squeeze(open).contains("case .perps: if let market = PerpAlertText.market(reference: reference) { pendingPerpMarket = market } tradeMode = .perps; tab = .trade"))
        XCTAssertTrue(hub.contains("func item(_ id: UUID) -> AppNotification? { items.first { $0.id == id } }"))
        XCTAssertTrue(squeeze(try appSource("Perps/PerpTradeView.swift")).contains("market: \"\\(market.asset)-PERP\", perpId: market.id)"), "the acknowledgement names its market too")
        for (path, text) in try appSources() where path != "App/Router.swift" && path != "App/RootView.swift" {
            XCTAssertFalse(text.contains("deliverPendingNotificationRoute()"), path)
            XCTAssertFalse(text.contains("pendingNotificationRoute ="), path)
        }

        let root = squeeze(try appSource("App/RootView.swift"))
        XCTAssertTrue(root.contains(".onChange(of: linkGateInput, initial: true) { _, _ in applyLinkGate() }"))
        XCTAssertTrue(root.contains("let busy = session.mera.runningActions > 0 || router.linkHolds > 0 || BiometricGate.isPrompting || session.mera.isPrompting"))
        XCTAssertTrue(root.contains("return LinkGateInput(pending: router.pendingLink != nil, route: router.pendingNotificationRoute, phase: phase, signedIn: session.address,"))
        XCTAssertTrue(root.contains("deletionScreen: session.passkeyDeletion != nil || session.deletionNotice != nil, busy: busy)"))
        XCTAssertTrue(root.contains("let decision = NotificationRouteGate.decide(link: input.pending, route: input.route, routeArrivedLast: router.notificationRouteArrivedLast,"))
        XCTAssertFalse(root.contains("MomentLinkGate.decide("), "one decision for both")
        XCTAssertTrue(root.contains("case .deliver?: router.deliverPendingLink() case .drop?: router.pendingLink = nil"))
        XCTAssertTrue(root.contains("case .deliver?: router.deliverPendingNotificationRoute() case .drop?: router.pendingNotificationRoute = nil case .hold?, nil: break"))
    }

    /// R4: N1 adds no UserDefaults key, and none of what it names starts with a prefix that marks an install as earlier
    /// than App Lock's default (`Theme.swift`'s `earlierRun`). The only such strings in its files are build 16's center
    /// and toggle keys.
    func testNoNewKeyMarksAnEarlierInstall() throws {
        let theme = try appSource("Design/Theme.swift")
        let earlierRun = try XCTUnwrap(theme.range(of: "let earlierRun = [")).upperBound
        let quotesAndSpace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))
        let prefixes = theme[earlierRun...].prefix { $0 != "]" }.split(separator: ",").map { $0.trimmingCharacters(in: quotesAndSpace) }
        XCTAssertTrue(prefixes.contains("notifications.") && prefixes.contains("settings."), "\(prefixes)")

        /// Every string literal in `text` that starts with one of the prefixes, up to its closing quote.
        func prefixed(_ text: String) -> Set<String> {
            var found: Set<String> = []
            for prefix in prefixes {
                for piece in text.components(separatedBy: "\"" + prefix).dropFirst() { found.insert(prefix + piece.prefix { $0 != "\"" }) }
            }
            return found
        }
        let files = ["Wallet/Notifications.swift", "Notifications/NotificationHub.swift", "App/Router.swift", "App/RootView.swift", "App/DyorHQApp.swift"]
        var found: Set<String> = []
        for file in files { found.formUnion(prefixed(try appSource(file))) }
        XCTAssertEqual(found, ["notifications.v1.", "settings.notifications"], "build 16's center and banner toggle keys only")

        for file in ["Services/Notifications/NotificationRouting.swift", "Services/Notifications/PerpOrderNotice.swift"] {
            let text = try kitSource(file)
            XCTAssertFalse(text.contains("UserDefaults"), file)
            XCTAssertEqual(prefixed(text), [], file)
        }
        for key in [NotificationTap.Key.item, NotificationTap.Key.route, NotificationTap.Key.account] {
            XCTAssertFalse(prefixes.contains { key.hasPrefix($0) }, key)
        }
    }
}
