import Foundation

/// The DyorHQ docs (GitBook, dyorhq.gitbook.io/docs), one case per page the app links to: the Help Center (the home), the
/// Learn rows of Get Help, and the "Learn more" links under a screen's own explanation. Each path is the page's published
/// GitBook path, checked live: GitBook's canonical paths differ from the docs repository's file paths, so a path is never
/// built from a file name, and none redirects. `DocsLinksTests` pins the table to the published pages, and with
/// DYOR_LIVE_DOCS=1 asks each one for a 200 without following a redirect.
public enum DocsLinks: String, CaseIterable, Sendable {
    /// The docs home: the Help Center.
    case home = ""
    case quickstart = "getting-started/quickstart"
    case selfCustodyAndSecurity = "platform/self-custody-and-security"
    case slippageAndPriceImpact = "spot-trading/slippage-and-price-impact"
    case depositAndWithdraw = "perpetuals/deposit-and-withdraw"
    case oneClickTrading = "perpetuals/one-click-trading"
    case launchACoin = "launchpad/launch-a-coin"
    case launchpadGraduation = "launchpad/graduation"
    case launchpadFeesAndRewards = "launchpad/fees-and-rewards"
    case publishAMoment = "moments/publish-a-moment"
    case collectAMoment = "moments/collect-a-moment"
    case momentsGraduationAndVesting = "moments/graduation-and-vesting"
    case momentsEarningsAndFees = "moments/earnings-and-fees"
    case bridge = "wallet-and-account/bridge"
    case notificationsAndPriceAlerts = "wallet-and-account/notifications-and-price-alerts"
    case exportSignOutDelete = "wallet-and-account/export-sign-out-delete"
    case contractsAndAddresses = "resources/contracts-and-addresses"
    case riskDisclosures = "resources/risk-disclosures"

    /// Where the docs live. The home is this URL itself, with no trailing slash.
    public static let base = "https://dyorhq.gitbook.io/docs"

    /// The page's published URL.
    public var url: URL {
        URL(string: rawValue.isEmpty ? Self.base : "\(Self.base)/\(rawValue)")!
    }

    /// The page's topic, for a link's accessibility label ("Learn more about …"), in the app's language.
    public var topic: String {
        switch self {
        case .home: return "DyorHQ" // not localized: the app's name
        case .quickstart: return L10n.string(LocalizedStringResource("getting started", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .selfCustodyAndSecurity: return L10n.string(LocalizedStringResource("self-custody and security", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .slippageAndPriceImpact: return L10n.string(LocalizedStringResource("slippage and price impact", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .depositAndWithdraw: return L10n.string(LocalizedStringResource("depositing and withdrawing collateral", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .oneClickTrading: return L10n.string(LocalizedStringResource("one-click trading", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .launchACoin: return L10n.string(LocalizedStringResource("launching a coin", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .launchpadGraduation: return L10n.string(LocalizedStringResource("graduation", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .launchpadFeesAndRewards: return L10n.string(LocalizedStringResource("launchpad fees and rewards", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .publishAMoment: return L10n.string(LocalizedStringResource("publishing a Moment", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .collectAMoment: return L10n.string(LocalizedStringResource("collecting a Moment", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .momentsGraduationAndVesting: return L10n.string(LocalizedStringResource("Moment graduation and vesting", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .momentsEarningsAndFees: return L10n.string(LocalizedStringResource("Moment earnings and fees", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .bridge: return L10n.string(LocalizedStringResource("bridging", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .notificationsAndPriceAlerts: return L10n.string(LocalizedStringResource("notifications and price alerts", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .exportSignOutDelete: return L10n.string(LocalizedStringResource("exporting, signing out and deleting", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .contractsAndAddresses: return L10n.string(LocalizedStringResource("contracts and addresses", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        case .riskDisclosures: return L10n.string(LocalizedStringResource("the risks", bundle: L10n.kit, comment: "The topic of a docs page, completing the accessibility label “Learn more about <topic>”."))
        }
    }
}
