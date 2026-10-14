import XCTest
@testable import DyorKit

/// The app's links into the DyorHQ docs (`DocsLinks`) go only to pages GitBook has published, at their canonical paths:
/// GitBook's paths differ from the docs repository's file paths, and a page that redirects or isn't published yet
/// (resources/faq, resources/past-cohorts-and-retired-launchpads, resources/security-and-responsible-disclosure) is never
/// linked. With DYOR_LIVE_DOCS=1, every link is asked for a 200 without following a redirect.
final class DocsLinksTests: XCTestCase {
    /// Every page published on 2026-09-28, each answering 200 at this exact URL.
    static let published: [String] = [
        "https://dyorhq.gitbook.io/docs",
        "https://dyorhq.gitbook.io/docs/getting-started/quickstart",
        "https://dyorhq.gitbook.io/docs/getting-started/create-your-account",
        "https://dyorhq.gitbook.io/docs/getting-started/fund-your-wallet",
        "https://dyorhq.gitbook.io/docs/getting-started/supported-network-and-assets",
        "https://dyorhq.gitbook.io/docs/platform/app-tour",
        "https://dyorhq.gitbook.io/docs/platform/self-custody-and-security",
        "https://dyorhq.gitbook.io/docs/platform/integrations-and-fees",
        "https://dyorhq.gitbook.io/docs/spot-trading/swap",
        "https://dyorhq.gitbook.io/docs/spot-trading/slippage-and-price-impact",
        "https://dyorhq.gitbook.io/docs/spot-trading/adding-tokens",
        "https://dyorhq.gitbook.io/docs/perpetuals/overview",
        "https://dyorhq.gitbook.io/docs/perpetuals/deposit-and-withdraw",
        "https://dyorhq.gitbook.io/docs/perpetuals/one-click-trading",
        "https://dyorhq.gitbook.io/docs/perpetuals/placing-orders",
        "https://dyorhq.gitbook.io/docs/perpetuals/managing-positions",
        "https://dyorhq.gitbook.io/docs/launchpad/overview",
        "https://dyorhq.gitbook.io/docs/launchpad/launch-a-coin",
        "https://dyorhq.gitbook.io/docs/launchpad/trading-on-the-curve",
        "https://dyorhq.gitbook.io/docs/launchpad/graduation",
        "https://dyorhq.gitbook.io/docs/launchpad/fees-and-rewards",
        "https://dyorhq.gitbook.io/docs/launchpad/my-launchpad",
        "https://dyorhq.gitbook.io/docs/moments/overview",
        "https://dyorhq.gitbook.io/docs/moments/publish-a-moment",
        "https://dyorhq.gitbook.io/docs/moments/collect-a-moment",
        "https://dyorhq.gitbook.io/docs/moments/graduation-and-vesting",
        "https://dyorhq.gitbook.io/docs/moments/earnings-and-fees",
        "https://dyorhq.gitbook.io/docs/moments/my-moments",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/home-and-portfolio",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/send-receive-transfer",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/bridge",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/notifications-and-price-alerts",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/profile-and-settings",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/dyorhq-social",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/export-sign-out-delete",
        "https://dyorhq.gitbook.io/docs/resources/contracts-and-addresses",
        "https://dyorhq.gitbook.io/docs/resources/risk-disclosures",
        "https://dyorhq.gitbook.io/docs/resources/glossary",
        "https://dyorhq.gitbook.io/docs/resources/official-links",
    ]

    /// Written in the docs but not published yet: never linked.
    static let unpublished = ["resources/faq", "resources/past-cohorts-and-retired-launchpads", "resources/security-and-responsible-disclosure"]

    func testEveryLinkIsAPublishedDocsPage() {
        XCTAssertEqual(Self.published.count, 39)
        XCTAssertEqual(Set(Self.published).count, Self.published.count, "no page twice")
        for page in DocsLinks.allCases {
            let url = page.url.absoluteString
            XCTAssertTrue(url.hasPrefix("https://dyorhq.gitbook.io/docs"), url)
            XCTAssertTrue(Self.published.contains(url), "\(page): \(url) is not a published page")
            XCTAssertFalse(url.hasSuffix("/"), "\(url): GitBook redirects a trailing slash")
            XCTAssertNil(page.url.query, url)
            XCTAssertNil(page.url.fragment, url)
            XCTAssertFalse(Self.unpublished.contains { url.hasSuffix($0) }, url)
            XCTAssertFalse(page.topic.isEmpty, url)
        }
        XCTAssertEqual(Set(DocsLinks.allCases.map(\.url)).count, DocsLinks.allCases.count, "one case per page")
        XCTAssertEqual(DocsLinks.base, "https://dyorhq.gitbook.io/docs")
    }

    /// The table itself: each case and the page it opens.
    func testTheTableIsPinned() {
        let expected: [(DocsLinks, String)] = [
            (.home, "https://dyorhq.gitbook.io/docs"),
            (.quickstart, "https://dyorhq.gitbook.io/docs/getting-started/quickstart"),
            (.selfCustodyAndSecurity, "https://dyorhq.gitbook.io/docs/platform/self-custody-and-security"),
            (.slippageAndPriceImpact, "https://dyorhq.gitbook.io/docs/spot-trading/slippage-and-price-impact"),
            (.depositAndWithdraw, "https://dyorhq.gitbook.io/docs/perpetuals/deposit-and-withdraw"),
            (.oneClickTrading, "https://dyorhq.gitbook.io/docs/perpetuals/one-click-trading"),
            (.launchACoin, "https://dyorhq.gitbook.io/docs/launchpad/launch-a-coin"),
            (.launchpadGraduation, "https://dyorhq.gitbook.io/docs/launchpad/graduation"),
            (.launchpadFeesAndRewards, "https://dyorhq.gitbook.io/docs/launchpad/fees-and-rewards"),
            (.publishAMoment, "https://dyorhq.gitbook.io/docs/moments/publish-a-moment"),
            (.collectAMoment, "https://dyorhq.gitbook.io/docs/moments/collect-a-moment"),
            (.momentsGraduationAndVesting, "https://dyorhq.gitbook.io/docs/moments/graduation-and-vesting"),
            (.momentsEarningsAndFees, "https://dyorhq.gitbook.io/docs/moments/earnings-and-fees"),
            (.bridge, "https://dyorhq.gitbook.io/docs/wallet-and-account/bridge"),
            (.notificationsAndPriceAlerts, "https://dyorhq.gitbook.io/docs/wallet-and-account/notifications-and-price-alerts"),
            (.exportSignOutDelete, "https://dyorhq.gitbook.io/docs/wallet-and-account/export-sign-out-delete"),
            (.contractsAndAddresses, "https://dyorhq.gitbook.io/docs/resources/contracts-and-addresses"),
            (.riskDisclosures, "https://dyorhq.gitbook.io/docs/resources/risk-disclosures"),
        ]
        XCTAssertEqual(DocsLinks.allCases, expected.map(\.0))
        for (page, url) in expected { XCTAssertEqual(page.url.absoluteString, url, "\(page)") }
    }

    // MARK: The app

    /// The app's sources (ios/DyorHQ), or a skip when this checkout has only the package.
    static func appSource(_ path: String) throws -> String {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }

    /// The Help Center is the docs home: Get Help leads with the Learn rows, and Profile's settings list it next to the
    /// Terms of Use and the Privacy Policy. The old dyorhq.fun/support page is gone.
    func testGetHelpAndProfileOpenTheDocs() throws {
        let help = try Self.appSource("Support/GetHelpView.swift")
        XCTAssertTrue(help.contains("static let helpCenter = DocsLinks.home.url"))
        XCTAssertFalse(help.contains("dyorhq.fun/support"))
        let learn = try XCTUnwrap(help.range(of: "group(\"Learn\")"), "Get Help has a Learn group")
        let getHelp = try XCTUnwrap(help.range(of: "group(\"Get Help\")"))
        XCTAssertLessThan(learn.lowerBound, getHelp.lowerBound, "Learn comes first")
        // Each row whole, in order: its title and description with the page it opens, so no two rows can trade links.
        let rows = help[learn.upperBound..<getHelp.lowerBound].split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("HelpRow(") }
        XCTAssertEqual(rows, [
            #"HelpRow(symbol: "book", title: "Help Center", detail: "Guides to every part of DyorHQ") { openURL(SupportLinks.helpCenter) }"#,
            #"HelpRow(symbol: "flag", title: "Getting Started", detail: "From sign-in to your first trade") { openURL(DocsLinks.quickstart.url) }"#,
            #"HelpRow(symbol: "exclamationmark.triangle", title: "Risk Disclosures", detail: "Read these before you trade") { openURL(DocsLinks.riskDisclosures.url) }"#,
            #"HelpRow(symbol: "checkmark.seal", title: "Contracts & Addresses", detail: "Verify every contract DyorHQ uses") { openURL(DocsLinks.contractsAndAddresses.url) }"#,
        ])
        let profile = try Self.appSource("Profile/ProfileView.swift")
        XCTAssertTrue(profile.contains("Link(destination: SupportLinks.helpCenter) { SettingsRow(\"Help Center\""))
        let helpCenter = try XCTUnwrap(profile.range(of: "SettingsRow(\"Help Center\""))
        let terms = try XCTUnwrap(profile.range(of: "SettingsRow(\"Terms of Use\""))
        XCTAssertLessThan(helpCenter.lowerBound, terms.lowerBound)
    }

    /// One "Learn more" in the app: the page, the file, the top-level view it sits in, and a phrase of the explanation it
    /// follows (in the lines just above it, after any earlier link in the file).
    struct Placement: Equatable, CustomStringConvertible {
        let page: String
        let file: String
        let view: String
        let follows: String

        init(_ page: String, _ file: String, _ view: String, follows: String) {
            self.page = page; self.file = file; self.view = view; self.follows = follows
        }

        var description: String { "\(page) in \(file) › \(view), after \"\(follows)\"" }
    }

    /// Each "Learn more" sits on the screen that explains its topic, under that explanation (a section footer or a line of
    /// help text), once: every link is matched to its page, file, view and explanation, and counted. The table holds only
    /// pages the app opens: those, plus Get Help's Learn rows. No screen writes a docs URL itself.
    func testEachLearnMoreLinkIsOnTheScreenThatExplainsIt() throws {
        let placements: [Placement] = [
            // Perpl Trading: the trading key's footer.
            .init("oneClickTrading", "Profile/Settings.swift", "PerplTradingView", follows: "Your trading key is generated on this device"),
            // Notifications: what reaches you, and when.
            .init("notificationsAndPriceAlerts", "Profile/Settings.swift", "NotificationsView", follows: "Alerts arrive while DyorHQ is open."),
            // Create Account: the first deposit, which opens the Perpl account.
            .init("depositAndWithdraw", "Perps/PerpsView.swift", "CollateralSheet", follows: "Your first deposit opens your Perpl account"),
            // The slippage sheet's explanation.
            .init("slippageAndPriceImpact", "Swap/SwapView.swift", "SlippageSheet", follows: "How far the price may move before your swap settles"),
            // Launch a Coin: the pairing footer.
            .init("launchACoin", "Launchpad/LaunchpadView.swift", "CreateLaunchView", follows: "Launch fee"),
            // The coin page: its creator fees, its gauge while the curve trades, its graduation section once it doesn't.
            .init("launchpadFeesAndRewards", "Launchpad/LaunchpadView.swift", "LaunchDetailView", follows: "they accrue in the fee escrow"),
            .init("launchpadGraduation", "Launchpad/LaunchpadView.swift", "LaunchDetailView", follows: "Graduates at"),
            .init("launchpadGraduation", "Launchpad/LaunchpadView.swift", "LaunchDetailView", follows: "The curve is full."),
            // Publish a Moment: the economics footer.
            .init("publishAMoment", "Moments/CreateMomentView.swift", "CreateMomentView", follows: "Collecting ends at graduation"),
            // A Moment: the collect section, Your Position (vesting and claims), You Created This (the creator's earnings).
            .init("collectAMoment", "Moments/MomentDetailView.swift", "MomentDetailView", follows: "Paid in USDC"),
            .init("momentsGraduationAndVesting", "Moments/MomentDetailView.swift", "MomentDetailView", follows: "Coins are minted to you as they vest"),
            .init("momentsEarningsAndFees", "Moments/MomentDetailView.swift", "MomentDetailView", follows: "accrue here for you"),
            // Bridge: under "Powered by Aurora Intents".
            .init("bridge", "Bridge/BridgeView.swift", "BridgeView", follows: "Powered by Aurora Intents"),
            // Export Wallet: the key warning. Delete Account: what is deleted.
            .init("exportSignOutDelete", "Wallet/WalletExportView.swift", "WalletExportView", follows: "Treat it like the keys to a safe"),
            .init("exportSignOutDelete", "Profile/AccountDeletion.swift", "DeleteAccountView", follows: "stay on the Monad blockchain"),
            // Sign-in: "DyorHQ never holds your keys".
            .init("selfCustodyAndSecurity", "Onboarding/OnboardingView.swift", "SignInView", follows: "DyorHQ never holds your keys or your funds."),
        ]
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() }
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let link = try NSRegularExpression(pattern: #"LearnMoreLink\(\.(\w+)\)"#)
        // A top-level type starts at column 0; one indented deeper is nested inside it.
        let declaration = try NSRegularExpression(pattern: #"^(?:@\w+ )*(?:(?:private|fileprivate|public|final) )*(?:struct|class|enum|extension|actor) (\w+)"#,
                                                  options: .anchorsMatchLines)
        var unmatched = placements
        var found = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = String(file.path.dropFirst(app.path.count + 1))
            XCTAssertFalse(text.contains("https://dyorhq.gitbook.io"), "\(relative): docs links come from DocsLinks")
            let whole = NSRange(text.startIndex..., in: text)
            let views = declaration.matches(in: text, range: whole).map { (start: $0.range.location, name: (text as NSString).substring(with: $0.range(at: 1))) }
            var previousEnd = 0
            for match in link.matches(in: text, range: whole) {
                found += 1
                let page = (text as NSString).substring(with: match.range(at: 1))
                XCTAssertNotNil(DocsLinks.allCases.first { "\($0)" == page }, page)
                let view = views.last { $0.start < match.range.location }
                // The explanation: the dozen lines above the link, within its view and after the file's previous link.
                let from = max(view?.start ?? 0, previousEnd)
                let window = (text as NSString).substring(with: NSRange(location: from, length: match.range.location - from))
                    .split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n")
                previousEnd = match.range.location + match.range.length
                let here = unmatched.firstIndex { $0.page == page && $0.file == relative && $0.view == view?.name && window.contains($0.follows) }
                if let here { unmatched.remove(at: here) } else {
                    XCTFail("LearnMoreLink(.\(page)) in \(relative) › \(view?.name ?? "?") is not a placement, or doesn't follow its explanation")
                }
            }
        }
        XCTAssertEqual(found, placements.count, "one link per placement")
        XCTAssertTrue(unmatched.isEmpty, "missing: \(unmatched)")
        // The coin page shows one of its two graduation links: under the gauge while the curve trades, or under the
        // graduation section once it doesn't.
        let launchpad = try Self.appSource("Launchpad/LaunchpadView.swift")
        XCTAssertTrue(launchpad.contains("if launch.phase == .bonding, launch.curveSellsOpen { LearnMoreLink(.launchpadGraduation) }"))
        XCTAssertTrue(launchpad.contains("if launch.curveSellsOpen { ticketSection } else { graduatedSection }"))
        // The first deposit's link stays while an amount under the minimum is typed: the problem takes the text's place.
        let perps = try Self.appSource("Perps/PerpsView.swift")
        XCTAssertTrue(perps.contains("if let problem { Text(verbatim: problem) }\n                            else { Paragraph(\"Your first deposit opens your Perpl account. Minimum 10 AUSD."))

        let linked = Set(placements.map(\.page)).union(["home", "quickstart", "riskDisclosures", "contractsAndAddresses"])
        XCTAssertEqual(linked, Set(DocsLinks.allCases.map { "\($0)" }), "one case per page the app opens, plus the home")
        let component = try Self.appSource("Design/Components.swift")
        XCTAssertTrue(component.contains("Link(\"Learn more\", destination: page.url)"))
    }

    // MARK: Live

    /// Every link answers 200 itself: no redirect is followed (a moved page answers 3xx here), so a link to a path GitBook
    /// only redirects from fails. Off by default: set DYOR_LIVE_DOCS=1.
    func testEveryLinkAnswers200WithoutARedirect() async throws {
        guard ProcessInfo.processInfo.environment["DYOR_LIVE_DOCS"] == "1" else { throw XCTSkip("set DYOR_LIVE_DOCS=1") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for page in DocsLinks.allCases {
            var request = URLRequest(url: page.url)
            request.httpMethod = "GET"
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            XCTAssertEqual(status, 200, "\(page.url.absoluteString) answered \(status.map(String.init) ?? "no HTTP status")"
                           + ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location").map { " → \($0)" } ?? ""))
        }
    }

    /// Get Help's "Verify every contract DyorHQ uses" row opens Contracts & Addresses, which names the contracts people
    /// may check: the v2 launchpad's modules other than its router, the v2 Moments' seven, and the shared PoolManager,
    /// Permit2 and USDC. The router and the Moments platform and treasury wallets are kept off the page on purpose (owner
    /// decision 2026-10-01). Off by default: set DYOR_LIVE_DOCS=1. The page never gates a release:
    /// `check-launchpad-addresses.py --release` only notes what it misses (`RetiredCohortGateTests`).
    func testTheContractsPageListsThisBuildsContracts() async throws {
        guard ProcessInfo.processInfo.environment["DYOR_LIVE_DOCS"] == "1" else { throw XCTSkip("set DYOR_LIVE_DOCS=1") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: DocsLinks.contractsAndAddresses.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let page = String(decoding: data, as: UTF8.self).lowercased()
        let l = LaunchpadAddresses.monadMainnet
        let m = MomentsAddresses.monadMainnet
        let called: [(String, Address)] = [
            ("launchpad factory", l.factory), ("fee escrow", l.escrow), ("holder fee sharing", l.holderFeeSharing),
            ("launchpad hook", l.hook), ("Moments factory", m.factory), ("Moments collect", m.collect), ("Moments vesting", m.vesting),
            ("Moments graduation", m.graduation), ("Moments locker", m.locker), ("Moments hook", m.hook), ("Moments buyback", m.buyback),
            ("PoolManager", l.poolManager), ("Moments PoolManager", m.poolManager),
            ("Permit2", m.permit2), ("USDC", m.usdc),
        ]
        XCTAssertFalse(called.contains { $0.1.isZero }, "a v2 table is pending")
        let missing = called.filter { !page.contains($0.1.hex.lowercased()) }.map { "\($0.0) \($0.1.hex)" }
        XCTAssertEqual(missing, [], "\(DocsLinks.contractsAndAddresses.url.absoluteString) does not list: \(missing.joined(separator: ", "))")
    }
}

/// Refuses every redirect, so the redirect response itself comes back.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
