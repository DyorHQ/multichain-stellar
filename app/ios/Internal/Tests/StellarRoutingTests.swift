// The Stellar section's shell (docs/DESIGN-stellar-parity.md §3.5, §3.6, §3.7, §8.13, §8.15): its tabs, the side menu's
// rows on Stellar, where each row and each Stellar reference leads, and the notifications its settled actions post.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import SwiftUI
import XCTest

@MainActor
final class StellarRoutingTests: XCTestCase {
    /// A coin's contract (C…), as a launch's reference names it.
    private let token = StrKey.contractID([UInt8](repeating: 7, count: 32))
    private let owner = Address(data: Data(repeating: 1, count: 20))!

    /// A router on `network`, where the account can use Stellar unless `available` is false, and is set up on this iPhone
    /// unless `setUp` is false.
    private func makeRouter(on network: AppNetwork = .stellar, available: Bool = true, setUp: Bool = true) -> Router {
        let router = Router()
        router.network = network
        router.stellarAvailable = available
        router.stellarIsSetUp = { available && setUp }
        return router
    }

    /// Waits up to `seconds` for `condition`, looking every 50 ms.
    private func waitUntil(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Tabs and menu

    func testTheTabsAreMonadsWithEarnInTradesSlot() {
        XCTAssertEqual(StellarTab.allCases, [.home, .launch, .earn, .moments])
        XCTAssertEqual(AppTab.allCases.firstIndex(of: .trade), StellarTab.allCases.firstIndex(of: .earn), "Earn sits in Trade's slot")
        XCTAssertEqual(StellarTradeMode.allCases, [.swap, .earn], "the switch reads Swap | Earn")
        XCTAssertEqual(Router().stellarTradeMode, .earn, "the Earn tab opens on Earn")
        XCTAssertEqual(StellarTradeMode.swap.label, TradeMode.swap.label)
        XCTAssertEqual(StellarTradeMode.earn.label, MenuItem.earnTitle)
    }

    func testTheMenuIsMonadsListWithEarnInPerpsRow() {
        XCTAssertEqual(MenuItem.items(for: .stellar), [.home, .spot, .earn, .launch, .moments, .news, .portfolio, .help])
        XCTAssertEqual(MenuItem.items(for: .monad), [.home, .spot, .perps, .launch, .moments, .news, .portfolio, .help],
                       "Monad's menu is build 23's")
    }

    func testEachRowsStellarTab() {
        let tabs: [MenuItem: StellarTab?] = [.home: .home, .spot: .earn, .earn: .earn, .launch: .launch, .moments: .moments,
                                             .perps: nil, .news: nil, .portfolio: nil, .help: nil]
        for item in MenuItem.allCases { XCTAssertEqual(item.stellarTab, tabs[item] ?? nil, "\(item)") }
    }

    func testTheRowsLinesOnStellar() {
        XCTAssertEqual(MenuItem.home.subtitle(on: .stellar), "Balances and markets")
        XCTAssertEqual(MenuItem.spot.subtitle(on: .stellar), "Swap across Stellar's venues")
        XCTAssertEqual(MenuItem.earn.subtitle(on: .stellar), "Lend XLM and USDC on Blend")
        XCTAssertEqual(MenuItem.launch.subtitle(on: .stellar), "Launch and trade coins on Stellar")
        XCTAssertEqual(MenuItem.moments.subtitle(on: .stellar), "Collect editions on Stellar")
        XCTAssertEqual(MenuItem.portfolio.subtitle(on: .stellar), "Volume, fees and P&L on Stellar")
        for item in [MenuItem.news, .help] { XCTAssertEqual(item.subtitle(on: .stellar), item.subtitle, "\(item) is both networks'") }
        for item in MenuItem.items(for: .monad) { XCTAssertEqual(item.subtitle(on: .monad), item.subtitle, "\(item) on Monad") }
        XCTAssertEqual(AppNetwork.stellar.summary, "Launch, swap, earn and collect")
    }

    // MARK: - References

    func testEveryDestinationReadsBackFromItsReference() {
        let destinations: [StellarDestination] = [
            .home, .portfolio,
            .swap(StellarSwapRequest()), .swap(StellarSwapRequest(sell: "XLM", buy: "USDC")),
            .swap(StellarSwapRequest(sell: nil, buy: token)), .swap(StellarSwapRequest(sell: "USDC", buy: nil)),
            .earn(market: nil), .earn(market: "\(token)XLM"),
            .launch(token: nil), .launch(token: token),
            .moment(id: nil), .moment(id: 0), .moment(id: 42),
            .bridge(id: nil), .bridge(id: "6f1c2a4e-0b7d-4c55-9a51-2d1e0f3b8c90"),
        ]
        for destination in destinations {
            XCTAssertTrue(destination.reference.hasPrefix("stellar:"), destination.reference)
            XCTAssertEqual(StellarDestination(reference: destination.reference), destination, destination.reference)
        }
        XCTAssertEqual(StellarDestination.home.reference, "stellar:home")
        XCTAssertEqual(StellarDestination.swap(StellarSwapRequest(sell: "XLM", buy: "USDC")).reference, "stellar:swap/XLM,USDC")
        XCTAssertEqual(StellarDestination.launch(token: token).reference, "stellar:launch/\(token)")
        XCTAssertEqual(StellarDestination.moment(id: 42).reference, "stellar:moment/42")
        // The starter swap is never in a reference.
        XCTAssertEqual(StellarDestination.swap(StellarSwapRequest(sell: "USDC", buy: "XLM", starter: true)).reference, "stellar:swap/USDC,XLM")
        XCTAssertEqual(StellarDestination(reference: "stellar:swap/USDC,XLM"), .swap(StellarSwapRequest(sell: "USDC", buy: "XLM")))
    }

    /// The references the store gives settled plans (`LiteStore`) are destinations.
    func testTheStoresReferencesAreDestinations() {
        XCTAssertEqual(StellarDestination(reference: "stellar:swap"), .swap(StellarSwapRequest()))
        XCTAssertEqual(StellarDestination(reference: "stellar:earn/\(token)XLM"), .earn(market: "\(token)XLM"))
        XCTAssertEqual(StellarDestination(reference: "stellar:launch"), .launch(token: nil))
        XCTAssertEqual(StellarDestination(reference: "stellar:moment"), .moment(id: nil))
        XCTAssertEqual(StellarDestination(reference: "stellar:bridge/abc-123"), .bridge(id: "abc-123"))
    }

    func testMonadReferencesAreRefused() {
        let monad = ["perp:16", "16", "42", "0x\(String(repeating: "ab", count: 20))/7", "https://dyorhq.fun/moments/sunset", "dyorhq://moments/7",
                     "", "stellar", "Stellar:home", "STELLAR:home", " stellar:home"]
        for reference in monad {
            XCTAssertNil(StellarDestination(reference: reference), reference)
            let router = makeRouter(on: .monad)
            XCTAssertFalse(router.openStellar(reference: reference), reference)
            XCTAssertEqual(router.network, .monad, reference)
        }
        XCTAssertFalse(makeRouter(on: .monad).openStellar(reference: nil))
    }

    func testMalformedStellarReferencesAreNotDestinations() {
        let malformed = ["stellar:", "stellar:home/1", "stellar:portfolio/2", "stellar:swap/", "stellar:swap/,", "stellar:swap/XLM",
                         "stellar:swap/XLM,USDC,EURC", "stellar:launch/0xabc", "stellar:launch/G\(String(repeating: "A", count: 55))",
                         "stellar:moment/-1", "stellar:moment/one", "stellar:moment/+5", "stellar:bridge/a/b", "stellar:bridge/a b",
                         "stellar:earn/\(String(repeating: "x", count: 129))", "stellar:trade", "stellar:moments/7"]
        for reference in malformed { XCTAssertNil(StellarDestination(reference: reference), reference) }
    }

    // MARK: - Opening a destination

    func testAStellarNotificationSwitchesToStellar() {
        let router = makeRouter(on: .monad)
        router.tab = .launch
        router.presented = .notifications
        router.open(route: .home, reference: "stellar:swap/XLM,USDC")
        XCTAssertEqual(router.network, .stellar)
        XCTAssertNil(router.presented)
        XCTAssertEqual(router.stellarTab, .earn)
        XCTAssertEqual(router.stellarTradeMode, .swap)
        XCTAssertEqual(router.pendingStellar, .swap(StellarSwapRequest(sell: "XLM", buy: "USDC")))
        XCTAssertEqual(router.tab, .launch, "Monad's tab is left as it was")
    }

    func testAStellarReferenceWithoutStellarStaysAndSaysWhy() {
        let router = makeRouter(on: .monad, available: false)
        router.tab = .moments
        router.open(route: .home, reference: "stellar:moment/3")
        XCTAssertEqual(router.network, .monad)
        XCTAssertEqual(router.tab, .moments, "not Monad's Home either")
        XCTAssertNil(router.pendingStellar)
        XCTAssertEqual(router.linkNotice, "Stellar isn't available for this account.")
    }

    /// Not set up on this iPhone (or signed out of Stellar): Stellar would only show its tabs waiting, so the app stays on
    /// Monad and the network sheet opens once the center has closed, its switch running the setup first.
    func testAStellarReferenceForAnAccountNotSetUpHereOpensTheNetworkSheet() async throws {
        let router = makeRouter(on: .monad, setUp: false)
        router.tab = .launch
        router.presented = .notifications
        router.open(route: .home, reference: "stellar:swap/XLM,USDC")
        XCTAssertEqual(router.network, .monad)
        XCTAssertNil(router.presented)
        XCTAssertNil(router.networkSheet, "not while the center is still closing")
        XCTAssertNil(router.pendingStellar)
        XCTAssertNil(router.linkNotice)
        try await waitUntil("the network sheet") { router.networkSheet != nil }
        XCTAssertEqual(router.networkSheet?.origin, .home)
        XCTAssertEqual(router.networkSheet?.startAt, .select)
        XCTAssertEqual(router.network, .monad)
        XCTAssertEqual(router.tab, .launch, "Monad's tab is left as it was")
    }

    func testOnStellarWithoutItsSetupAReferenceGoesBackToMonadForTheSheet() async throws {
        let router = makeRouter(on: .stellar, setUp: false)
        router.menuOpen = true
        XCTAssertTrue(router.openStellar(reference: "stellar:launch"))
        XCTAssertEqual(router.network, .monad, "the sheet's Stellar row is the current network's otherwise, and off")
        XCTAssertFalse(router.menuOpen)
        try await waitUntil("the network sheet") { router.networkSheet != nil }
    }

    func testTheNetworkSheetDoesntOpenOverWhatOpenedMeanwhile() async throws {
        let router = makeRouter(on: .monad, setUp: false)
        router.open(route: .home, reference: "stellar:home")
        router.presented = .profile
        try await Task.sleep(for: Router.coverCloses + .milliseconds(300))
        XCTAssertNil(router.networkSheet)
        XCTAssertEqual(router.presented, .profile)
    }

    func testASetUpAccountsReferenceNeverOpensTheSheet() async throws {
        let router = makeRouter(on: .monad)
        router.open(route: .home, reference: "stellar:home")
        XCTAssertEqual(router.network, .stellar)
        try await Task.sleep(for: Router.coverCloses + .milliseconds(300))
        XCTAssertNil(router.networkSheet)
    }

    /// `NetworkRoot.keep`'s wiring: the session's plan is read each time it is asked, so a setup or a Sign out of Stellar
    /// counts at once.
    func testTheRouterReadsTheSessionsPlanWhenAsked() {
        let address = StrKey.accountID([UInt8](repeating: 9, count: 32))
        let keys = [LiteSession.activatedKey(address), LiteSession.signedOutKey(address)]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let router = Router()
        XCTAssertFalse(router.stellarAvailable)
        XCTAssertFalse(router.stellarIsSetUp())
        let lite = LiteSession(env: LiteGate.environment, stellarAddress: address, monad: nil, keys: nil)
        router.keepStellar(lite)
        XCTAssertTrue(router.stellarAvailable)
        XCTAssertFalse(router.stellarIsSetUp(), "not set up on this iPhone")
        UserDefaults.standard.set(true, forKey: LiteSession.activatedKey(address))
        XCTAssertTrue(router.stellarIsSetUp())
        UserDefaults.standard.set(true, forKey: LiteSession.signedOutKey(address))
        XCTAssertFalse(router.stellarIsSetUp(), "signed out of Stellar: the next switch signs in")
        UserDefaults.standard.removeObject(forKey: LiteSession.signedOutKey(address))
        XCTAssertTrue(router.stellarIsSetUp())
        router.keepStellar(nil)
        XCTAssertFalse(router.stellarAvailable)
        XCTAssertFalse(router.stellarIsSetUp())
    }

    func testAMonadNotificationOnStellarSwitchesToMonad() {
        let router = makeRouter(on: .stellar)
        router.open(route: .perps, reference: "perp:16")
        XCTAssertEqual(router.network, .monad)
        XCTAssertEqual(router.tab, .trade)
        XCTAssertEqual(router.tradeMode, .perps)
        XCTAssertEqual(router.pendingPerpMarket, 16)
    }

    func testAReferenceThisBuildCantReadOpensStellarHome() {
        let router = makeRouter(on: .monad)
        router.stellarTab = .moments
        XCTAssertTrue(router.openStellar(reference: "stellar:vaults/9"))
        XCTAssertEqual(router.network, .stellar)
        XCTAssertEqual(router.stellarTab, .home)
    }

    func testEachDestinationsTabSideAndPending() {
        let cases: [(StellarDestination, StellarTab, StellarTradeMode, StellarDestination?)] = [
            (.home, .home, .earn, nil),
            (.swap(StellarSwapRequest()), .earn, .swap, .swap(StellarSwapRequest())),
            (.earn(market: nil), .earn, .earn, nil),
            (.earn(market: "m1"), .earn, .earn, .earn(market: "m1")),
            (.launch(token: nil), .launch, .earn, nil),
            (.launch(token: token), .launch, .earn, .launch(token: token)),
            (.moment(id: nil), .moments, .earn, nil),
            (.moment(id: 5), .moments, .earn, .moment(id: 5)),
            (.bridge(id: "t1"), .home, .earn, .bridge(id: "t1")),
        ]
        for (destination, tab, mode, pending) in cases {
            let router = makeRouter()
            router.pendingStellar = .moment(id: 99)
            router.menuOpen = true
            router.presented = .profile
            router.openStellar(destination)
            XCTAssertEqual(router.stellarTab, tab, "\(destination)")
            XCTAssertEqual(router.stellarTradeMode, mode, "\(destination)")
            XCTAssertEqual(router.pendingStellar, pending, "\(destination)")
            XCTAssertFalse(router.menuOpen, "\(destination)")
            XCTAssertNil(router.presented, "\(destination)")
            XCTAssertEqual(router.network, .stellar)
        }
        let router = makeRouter()
        router.stellarTab = .launch
        router.openStellar(.portfolio)
        XCTAssertEqual(router.presented, .portfolio)
        XCTAssertEqual(router.stellarTab, .launch, "Portfolio opens over the tab")
    }

    func testEverySwapEntryOpensTheSwapSide() {
        let router = makeRouter()
        router.openStellarSwap(sell: "USDC", buy: "XLM", starter: true)
        XCTAssertEqual(router.stellarTab, .earn)
        XCTAssertEqual(router.stellarTradeMode, .swap)
        XCTAssertEqual(router.pendingStellar, .swap(StellarSwapRequest(sell: "USDC", buy: "XLM", starter: true)))
    }

    // MARK: - The side menu on Stellar

    func testEveryMenuRowOnStellar() {
        for item in MenuItem.allCases {
            let router = makeRouter()
            router.menuOpen = true
            router.tab = .moments
            router.open(item)
            XCTAssertFalse(router.menuOpen, "\(item)")
            switch item {
            case .home:
                XCTAssertEqual(router.stellarTab, .home)
            case .spot:
                XCTAssertEqual(router.stellarTab, .earn)
                XCTAssertEqual(router.stellarTradeMode, .swap, "Spot opens Earn in Swap mode")
                XCTAssertEqual(router.pendingStellar, .swap(StellarSwapRequest()))
            case .earn:
                XCTAssertEqual(router.stellarTab, .earn)
                XCTAssertEqual(router.stellarTradeMode, .earn)
            case .launch:
                XCTAssertEqual(router.stellarTab, .launch)
            case .moments:
                XCTAssertEqual(router.stellarTab, .moments)
            case .portfolio:
                XCTAssertEqual(router.presented, .portfolio, "Stellar's Portfolio (AppCovers)")
            case .news:
                XCTAssertEqual(router.presented, .news)
            case .help:
                XCTAssertEqual(router.presented, .help)
            case .perps:
                XCTAssertEqual(router.network, .monad, "Perps is Monad's")
                XCTAssertEqual(router.tab, .trade)
                XCTAssertEqual(router.tradeMode, .perps)
                continue
            }
            XCTAssertEqual(router.network, .stellar, "\(item) stays on Stellar")
            XCTAssertEqual(router.tab, .moments, "\(item): Monad's tab is left as it was")
        }
    }

    func testOpenOnStellarHandlesStellarsRowsOnly() {
        for item in MenuItem.allCases {
            let handled = makeRouter().openOnStellar(item)
            XCTAssertEqual(handled, ![.news, .help, .perps].contains(item), "\(item)")
        }
    }

    func testTheMenuOnMonadIsBuild23s() {
        let router = makeRouter(on: .monad)
        router.open(.spot)
        XCTAssertEqual(router.tab, .trade)
        XCTAssertEqual(router.tradeMode, .swap)
        XCTAssertNil(router.pendingStellar)
        router.open(.portfolio)
        XCTAssertEqual(router.presented, .portfolio)
        XCTAssertEqual(router.network, .monad)
    }

    func testTheNowBadgeFollowsTheTabAndTheSwitch() {
        let router = makeRouter()
        router.stellarTab = .earn
        router.stellarTradeMode = .swap
        XCTAssertEqual(MenuItem.items(for: .stellar).filter(router.isCurrentOnStellar), [.spot])
        router.stellarTradeMode = .earn
        XCTAssertEqual(MenuItem.items(for: .stellar).filter(router.isCurrentOnStellar), [.earn])
        router.stellarTab = .launch
        XCTAssertEqual(MenuItem.items(for: .stellar).filter(router.isCurrentOnStellar), [.launch])
        router.stellarTab = .home
        XCTAssertEqual(MenuItem.items(for: .stellar).filter(router.isCurrentOnStellar), [.home])
    }

    // MARK: - Notifications

    private func settled(_ planId: String = "p1", kind: String, section: LiteSection, title: String = "Swap complete",
                         body: String = "Swapped 10 XLM → 1.2 USDC", reference: String? = "stellar:swap") -> LiteSettledAction {
        LiteSettledAction(planId: planId, kind: kind, title: title, body: body, section: section, reference: reference, hashes: ["h"],
                          at: Date())
    }

    private func recorder(testnet: Bool = true) -> (StellarActivityRecorder, () -> [StellarActivityRecorder.Post], UserDefaults) {
        let suite = "StellarRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var posts: [StellarActivityRecorder.Post] = []
        let recorder = StellarActivityRecorder(owner: owner, isTestnet: testnet, defaults: defaults) { posts.append($0) }
        return (recorder, { posts }, defaults)
    }

    func testASettledSwapPostsOnceToTheAccountsCenter() {
        let (recorder, posts, defaults) = recorder()
        let account = StrKey.accountID([UInt8](repeating: 4, count: 32))
        recorder.record(settled(kind: "swap", section: .spot), account: account)
        recorder.record(settled(kind: "swap", section: .spot), account: account)
        XCTAssertEqual(posts(), [StellarActivityRecorder.Post(kind: .swap, title: "Swap complete", body: "Swapped 10 XLM → 1.2 USDC · Stellar testnet",
                                                              route: .home, reference: "stellar:swap", owner: owner)])
        XCTAssertEqual(defaults.stringArray(forKey: "lite.notified.\(account)"), ["plan.p1"], "erased with the account (forget)")
        // A recorder made at the next launch remembers it.
        var again: [StellarActivityRecorder.Post] = []
        StellarActivityRecorder(owner: owner, isTestnet: true, defaults: defaults) { again.append($0) }
            .record(settled(kind: "swap", section: .spot), account: account)
        XCTAssertEqual(again, [])
    }

    func testEachActionsKind() {
        XCTAssertEqual(StellarActivityRecorder.kind(of: settled(kind: "swap", section: .spot)), .swap)
        XCTAssertEqual(StellarActivityRecorder.kind(of: settled(kind: "swap", section: .launch)), .swap, "a swap of a coin is a swap")
        XCTAssertEqual(StellarActivityRecorder.kind(of: settled(kind: "bridge_out", section: .bridge)), .swap)
        XCTAssertEqual(StellarActivityRecorder.kind(of: settled(kind: "moment_collect", section: .moments)), .moments)
        XCTAssertEqual(StellarActivityRecorder.kind(of: settled(kind: "moment_publish", section: .moments)), .moments)
        for (kind, section) in [("payment", LiteSection.spot), ("earn_deposit", .earn), ("earn_withdraw", .earn), ("launch_buy", .launch),
                                ("launch_sell", .launch), ("launch_create", .launch), ("launch_graduate", .launch), ("launch_claim", .launch)] {
            XCTAssertEqual(StellarActivityRecorder.kind(of: settled(kind: kind, section: section)), .transaction, kind)
        }
        for kind in ["trust", "restore", "faucet", "activate"] {
            XCTAssertNil(StellarActivityRecorder.kind(of: settled(kind: kind, section: .account)), "\(kind): Activity only")
        }
    }

    func testEnablingAnAssetPostsNothing() {
        let (recorder, posts, _) = recorder()
        recorder.record(settled(kind: "trust", section: .account, title: "Enabled USDC", body: ""), account: "G1")
        XCTAssertEqual(posts(), [])
    }

    func testTheBodyNamesTheNetwork() {
        let (testnet, _, _) = recorder(testnet: true)
        XCTAssertEqual(testnet.withNetwork("Swapped 10 XLM → 1.2 USDC"), "Swapped 10 XLM → 1.2 USDC · Stellar testnet")
        XCTAssertEqual(testnet.withNetwork(""), "Stellar testnet")
        let (mainnet, _, _) = recorder(testnet: false)
        XCTAssertEqual(mainnet.withNetwork("Sent"), "Sent · Stellar")
    }

    func testAPostWithoutAReferenceOpensStellarHome() {
        let (recorder, posts, _) = recorder()
        XCTAssertTrue(recorder.notify(id: "bridge.t1", kind: .swap, title: "Bridge complete", body: "", reference: nil, account: "G1"))
        XCTAssertFalse(recorder.notify(id: "bridge.t1", kind: .swap, title: "Bridge complete", body: "", reference: nil, account: "G1"))
        XCTAssertEqual(posts().map(\.reference), ["stellar:home"])
        XCTAssertEqual(posts().map(\.route), [.home])
    }

    func testAnAccountWithNoStellarAddressYetStillPostsOnce() {
        let (recorder, posts, _) = recorder()
        recorder.record(settled(kind: "launch_buy", section: .launch, reference: "stellar:launch/\(token)"), account: nil)
        recorder.record(settled(kind: "launch_buy", section: .launch, reference: "stellar:launch/\(token)"), account: nil)
        XCTAssertEqual(posts().count, 1)
        XCTAssertEqual(posts().first?.reference, "stellar:launch/\(token)")
    }

    func testTheRecorderRemembersALimitedNumberOfIds() {
        let (recorder, posts, defaults) = recorder()
        for i in 0..<(StellarActivityRecorder.remembered + 5) {
            recorder.notify(id: "plan.\(i)", kind: .transaction, title: "Sent", body: "1 XLM", reference: nil, account: "G1")
        }
        XCTAssertEqual(posts().count, StellarActivityRecorder.remembered + 5)
        let kept = defaults.stringArray(forKey: StellarActivityRecorder.key("G1")) ?? []
        XCTAssertEqual(kept.count, StellarActivityRecorder.remembered)
        XCTAssertEqual(kept.last, "plan.\(StellarActivityRecorder.remembered + 4)", "the newest are kept")
    }

    /// Through the app's own center: a settled swap is filed once in the account's bell, and its row, tapped while on
    /// Monad, opens Stellar's Swap. (The account isn't the one the center shows, so nothing is mirrored anywhere.)
    func testASettledSwapAppearsOnceInTheAccountsBell() throws {
        let account = Address(data: Data(repeating: 0x5e, count: 20))!
        XCTAssertNotEqual(NotificationHub.shared.owner, account)
        let bellKey = "notifications.v1." + account.hex.lowercased()
        defer { UserDefaults.standard.removeObject(forKey: bellKey) }
        let (_, _, notified) = recorder()
        let recorder = StellarActivityRecorder(owner: account, isTestnet: true, defaults: notified)
        let stellar = StrKey.accountID([UInt8](repeating: 4, count: 32))
        recorder.record(settled("swap-1", kind: "swap", section: .spot), account: stellar)
        recorder.record(settled("swap-1", kind: "swap", section: .spot), account: stellar)
        let bell = NotificationStore.all(owner: account)
        XCTAssertEqual(bell.count, 1)
        let row = try XCTUnwrap(bell.first)
        XCTAssertEqual(row.kind, .swap)
        XCTAssertEqual(row.title, "Swap complete")
        XCTAssertEqual(row.body, "Swapped 10 XLM → 1.2 USDC · Stellar testnet")
        XCTAssertEqual(row.route, .home)
        let router = makeRouter(on: .monad)
        router.open(row)
        XCTAssertEqual(router.network, .stellar)
        XCTAssertEqual(router.stellarTab, .earn)
        XCTAssertEqual(router.stellarTradeMode, .swap)
    }

    /// The posted reference opens the action's screen: a Stellar notification tapped while on Monad.
    func testAPostedNotificationOpensItsStellarScreen() throws {
        let (recorder, posts, _) = recorder()
        recorder.record(settled(kind: "launch_buy", section: .launch, title: "Bought ABC", body: "10 XLM", reference: "stellar:launch/\(token)"),
                        account: "G1")
        let post = try XCTUnwrap(posts().first)
        let router = makeRouter(on: .monad)
        router.open(route: post.route, reference: post.reference)
        XCTAssertEqual(router.network, .stellar)
        XCTAssertEqual(router.stellarTab, .launch)
        XCTAssertEqual(router.pendingStellar, .launch(token: token))
    }
    // MARK: - The app's sign-out

    private final class FakeStellarSession {
        var signedOut = false
    }

    /// Session.swift's sign-out and erase wait for the Stellar sign-out before `LiteKeyBootstrap.forget`.
    func testTheAppsSignOutWaitsForTheStellarSignOut() async {
        defer { StellarLiveSession.hold(nil, owner: nil) }
        let fake = FakeStellarSession()
        StellarLiveSession.hold(fake, owner: owner) {
            try? await Task.sleep(for: .milliseconds(100))
            fake.signedOut = true
        }
        XCTAssertTrue(StellarLiveSession.holds(fake))
        await StellarLiveSession.signOut(owner: owner)
        XCTAssertTrue(fake.signedOut, "done before the caller goes on")
        XCTAssertFalse(StellarLiveSession.holds(fake), "let go: its own sign-out hook leaves the network alone")
    }

    func testTheAppsSignOutWaitsAtMostItsLimit() async {
        defer { StellarLiveSession.hold(nil, owner: nil) }
        let fake = FakeStellarSession()
        StellarLiveSession.hold(fake, owner: owner) {
            try? await Task.sleep(for: .seconds(30))
            fake.signedOut = true
        }
        let start = ContinuousClock.now
        await StellarLiveSession.signOut(owner: owner, limit: .milliseconds(200))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
        XCTAssertFalse(fake.signedOut, "still going on behind")
        XCTAssertFalse(StellarLiveSession.holds(fake))
    }

    func testTheDefaultLimitIsThreeSeconds() async {
        defer { StellarLiveSession.hold(nil, owner: nil) }
        StellarLiveSession.hold(FakeStellarSession(), owner: owner) { try? await Task.sleep(for: .seconds(30)) }
        let start = ContinuousClock.now
        await StellarLiveSession.signOut(owner: owner)
        let waited = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(2900))
        XCTAssertLessThan(waited, .seconds(6))
    }

    func testAnotherAccountsSignOutLeavesTheSessionAlone() async {
        defer { StellarLiveSession.hold(nil, owner: nil) }
        let fake = FakeStellarSession()
        StellarLiveSession.hold(fake, owner: owner) { fake.signedOut = true }
        await StellarLiveSession.signOut(owner: Address(data: Data(repeating: 2, count: 20))!)
        XCTAssertFalse(fake.signedOut)
        XCTAssertTrue(StellarLiveSession.holds(fake))
        // Dropped with the account (`NetworkRoot.keep(nil)`): nothing left to sign out.
        StellarLiveSession.hold(nil, owner: nil)
        XCTAssertFalse(StellarLiveSession.holds(fake))
        await StellarLiveSession.signOut(owner: owner)
        XCTAssertFalse(fake.signedOut)
    }

    // MARK: - Receive over a review

    /// Closes itself with SwiftUI's `dismiss`, as Receive's Close does, a moment after it appears.
    private struct DismissProbe: View {
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            Text(verbatim: "Receive").task {
                try? await Task.sleep(for: .milliseconds(400))
                dismiss()
            }
        }
    }

    /// `StellarActions.addFunds` from a review sheet: Receive opens over the sheet (SwiftUI would drop a sheet of the
    /// root's), and its own Close takes it away, back to the sheet.
    func testReceiveOpensOverWhatIsPresentedAndClosesWithItsDismiss() async throws {
        let base = try XCTUnwrap(StellarPresenter.top, "the app's window")
        let review = UIViewController()
        base.present(review, animated: false)
        try await waitUntil("the review") { base.presentedViewController === review }
        XCTAssertTrue(StellarPresenter.top === review)
        let receive = UIHostingController(rootView: DismissProbe())
        StellarPresenter.present(receive)
        try await waitUntil("Receive over the review") { review.presentedViewController === receive }
        XCTAssertTrue(StellarPresenter.top === receive)
        try await waitUntil("Receive closed by its dismiss") { review.presentedViewController == nil }
        XCTAssertTrue(StellarPresenter.top === review, "the review is still there")
        review.dismiss(animated: false)
        try await waitUntil("the review closed") { base.presentedViewController == nil }
    }
}
