// Stellar Portfolio's figures: each period's volume, fees, P&L, fees received and trades, in total and per section, as
// /v1/portfolio states them, what was saved when they were last read, and the holdings it lists (docs/DESIGN-stellar-parity.md
// §8.12.1, §6.5, §6.7, §3.9). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import BigInt
import DyorKit
import DyorLite
import Foundation
import StellarKit

/// Stellar Portfolio's figures, kept as Monad's `PortfolioModel` keeps Monad's. Each period's figures are DyorHQ's history
/// (`/v1/portfolio`, through `LiteStore`), which needs a session: a seed account gets one silently, and a passkey account
/// whose session is gone reads nothing until it signs in from the screen (decision 6). The holdings the Assets card lists
/// are a viewer read (`/v1/holdings`), with or without a session.
///
/// What each period showed is saved for the account (`StellarSaved`, screen `.portfolio`) and shown before the screen's
/// first frame, said to be saved, until the period's own read lands. Sign-out erases the file (`StellarSaved.forget`)
/// and the figures on screen (`forget`).
@MainActor
@Observable
final class StellarPortfolioModel {
    /// Monad's sections, with Earn in Perps' place and no Bridge, which Stellar doesn't have for now.
    enum Section: String, CaseIterable, Identifiable {
        case spot, earn, launch, moments
        var id: String { rawValue }

        /// Monad's section names, and Stellar's Earn.
        var title: String {
            switch self {
            case .spot: return PortfolioModel.Section.spot.title
            case .earn: return MenuItem.earnTitle
            case .launch: return PortfolioModel.Section.launch.title
            case .moments: return PortfolioModel.Section.moments.title
            }
        }

        /// Monad's section symbols, and the Earn tab's leaf.
        var symbol: String {
            switch self {
            case .earn: return "leaf"
            case .spot: return PortfolioModel.Section.spot.symbol
            case .launch: return PortfolioModel.Section.launch.symbol
            case .moments: return PortfolioModel.Section.moments.symbol
            }
        }

        /// Where a tap on the section's header goes (`Router.open`, which on Stellar opens Stellar's tab or side): Spot is
        /// the Earn tab's Swap side, Earn its Earn side.
        var menuItem: MenuItem {
            switch self {
            case .spot: return .spot
            case .earn: return .earn
            case .launch: return .launch
            case .moments: return .moments
            }
        }

        func stats(_ sections: StellarPortfolio.Sections) -> StellarStats {
            switch self {
            case .spot: return sections.spot
            case .earn: return sections.earn
            case .launch: return sections.launch
            case .moments: return sections.moments
            }
        }
    }

    /// A section's figures over a period, or the period's totals, as the server states them (`StellarStats`): zero while
    /// none are read, which the screen shows as placeholders, never as "$0.00".
    struct Stats: Codable, Hashable, Sendable {
        var volume = 0.0
        var fees = 0.0
        var pnl = 0.0
        /// Creator fees claimed and Moments proceeds: the "Fees received" figure.
        var claimedFees = 0.0
        var trades = 0
        /// False when some trades' outcome is missing from `pnl`, which then reads as a lower bound ("*").
        var pnlComplete = true
        /// The network fees paid in XLM, in stroops: never part of `fees`.
        var networkFeesStroops: Int64 = 0

        init() {}

        init(_ stats: StellarStats) {
            volume = stats.volume
            fees = stats.fees
            pnl = stats.pnl
            claimedFees = stats.claimedFees
            trades = stats.trades
            pnlComplete = stats.pnlComplete
            networkFeesStroops = Int64(stats.networkFeesXlm) ?? 0
        }

        /// `parts` added up, as the server adds its sections up into its totals.
        init(adding parts: [Stats]) {
            volume = parts.reduce(0) { $0 + $1.volume }
            fees = parts.reduce(0) { $0 + $1.fees }
            pnl = parts.reduce(0) { $0 + $1.pnl }
            claimedFees = parts.reduce(0) { $0 + $1.claimedFees }
            trades = parts.reduce(0) { $0 + $1.trades }
            pnlComplete = parts.allSatisfy(\.pnlComplete)
            networkFeesStroops = parts.reduce(0) { $0 + $1.networkFeesStroops }
        }
    }

    /// One period's figures: the totals and each section's, and when they were read.
    struct Figures: Codable, Equatable, Sendable {
        var totals: Stats
        /// By `Section.rawValue`.
        var sections: [String: Stats]
        var readAt: Date

        init(_ portfolio: StellarPortfolio, now: Date = Date()) {
            totals = StellarPortfolioModel.totals(portfolio)
            sections = Dictionary(uniqueKeysWithValues: Section.allCases.map { ($0.rawValue, Stats($0.stats(portfolio.sections))) })
            readAt = StellarFormat.date(portfolio.asOf).map { min($0, now) } ?? now
        }

        func stats(_ section: Section) -> Stats? { sections[section.rawValue] }
    }

    /// What Portfolio saves for an account (`SavedScreens.Screen.portfolio`): each period's figures, never its activity.
    struct Saved: Codable, Sendable {
        /// The Stellar account the figures are of: a file for another is never shown.
        var stellar: String
        /// By `VolumePeriodKey.rawValue`.
        var periods: [String: Figures]
    }

    /// A period's figures as the screen shows them: this session's read, else what was saved, with when it was read.
    struct Shown: Equatable {
        let figures: Figures
        /// When the saved figures shown were read; nil for this session's.
        let savedAt: Date?
    }

    /// One action of the period, in Activity.
    struct Row: Identifiable, Equatable {
        let item: StellarPortfolio.Item
        /// Its section; nil for a past bridge's (`pastBridge`), listed as plain history that no section or total counts.
        let section: Section?
        let time: Date?
        var id: String { item.id }

        /// Its section's mark, or Monad's Bridge mark for a past bridge's.
        var symbol: String { section?.symbol ?? PortfolioModel.Section.bridge.symbol }
        /// Its section's name, or Monad's "Bridge" for a past bridge's: what the row says when nothing else words it.
        var sectionTitle: String { section?.title ?? PortfolioModel.Section.bridge.title }
    }

    /// The server's section for a bridge between Monad and Stellar. Stellar has no Bridge for now, but an account's past
    /// bridges stay in Activity, as plain history.
    nonisolated static let pastBridge = "bridge"

    /// A token the Assets card lists: a Spot holding or a launch coin.
    enum Asset: Identifiable, Equatable {
        case spot(StellarHoldings.SpotHolding)
        case coin(StellarHoldings.LaunchHolding)

        var id: String {
            switch self {
            case .spot(let row): return "spot-\(row.id)"
            case .coin(let coin): return "coin-\(coin.token)"
            }
        }

        var valueUsd: Double? {
            switch self {
            case .spot(let row): return row.valueUsd
            case .coin(let coin): return coin.valueUsd
            }
        }

        var code: String {
            switch self {
            case .spot(let row): return row.code
            case .coin(let coin): return coin.symbol
            }
        }
    }

    /// An edition the NFTs grid shows, keyed by its NFT contract and its number: every v2 Moment has a contract of its
    /// own that numbers its editions from 1, and v1's editions are listed with them, so a number alone is no key.
    struct Edition: Identifiable, Equatable {
        let edition: StellarEdition
        var id: String { "\(edition.contract ?? "")#\(edition.tokenId)" }
    }

    /// Each period's figures as saved when the account was last read: shown, said to be saved, until the period's own read
    /// lands (`LiteStore.portfolio`).
    private(set) var savedFigures: [VolumePeriodKey: Figures] = [:]
    /// The launch coins the account holds that were launched on the retired v1 launchpad (generation 1): "Retired".
    private(set) var retiredCoins: Set<String> = []
    private var loads = 0

    /// The figures read in this session, by period, for what Portfolio saves.
    @ObservationIgnored private var liveFigures: [VolumePeriodKey: Figures] = [:]
    /// Whether the coins' launchpad generation was read for the account's coins in this session.
    @ObservationIgnored private var retiredRead = false
    /// Whose figures the model holds: the signed-in account (its Monad address keys the saved file) and its Stellar
    /// address.
    @ObservationIgnored private var owner: Address?
    @ObservationIgnored private var stellar: String?
    /// The save guard taken when the account's figures were first shown: a save after a sign-out or an erase is dropped.
    @ObservationIgnored private var epoch: StellarSaved.Epoch?
    @ObservationIgnored private let saved: StellarSaved

    init(saved: StellarSaved = .shared) {
        self.saved = saved
    }

    /// A read of Portfolio's own is under way (opening, a period change, a pull, a Retry).
    var loading: Bool { loads > 0 }

    // MARK: Figures

    /// A period's totals as Stellar shows them: its sections' figures added up. The server's totals count the Bridge's
    /// too, which Stellar doesn't have for now. Home's Total Volume is this volume, so the two screens agree.
    nonisolated static func totals(_ portfolio: StellarPortfolio) -> Stats {
        Stats(adding: Section.allCases.map { Stats($0.stats(portfolio.sections)) })
    }

    /// `key`'s figures as shown: this session's read (`live`), else those saved when the account was last read, else nil
    /// (placeholders, never $0.00). Nothing while DyorHQ's history needs a sign-in the user hasn't asked for: the screen
    /// offers it instead (decision 6).
    func shown(_ key: VolumePeriodKey, live: StellarPortfolio?, status: LiteReadStatus, now: Date = Date()) -> Shown? {
        guard status != .needsSignIn else { return nil }
        if let live { return Shown(figures: Figures(live, now: now), savedAt: nil) }
        return savedFigures[key].map { Shown(figures: $0, savedAt: $0.readAt) }
    }

    /// The period's activity as the server lists it, in its order: each item in a section Portfolio shows, and each past
    /// bridge's.
    static func rows(_ portfolio: StellarPortfolio?) -> [Row] {
        (portfolio?.activity ?? []).compactMap { item in
            let section = Section(rawValue: item.section)
            guard section != nil || item.section == pastBridge else { return nil }
            return Row(item: item, section: section, time: StellarFormat.date(item.at))
        }
    }

    // MARK: Holdings

    /// The tokens the account holds, the most valuable first (ties in the server's order): Spot holdings with a balance,
    /// then the launch coins, as one list, as Monad's lists every token it holds.
    static func assets(_ holdings: StellarHoldings?) -> [Asset] {
        guard let holdings else { return [] }
        let spot = holdings.spot.filter { (BigUInt($0.balance) ?? 0) > 0 }.map(Asset.spot)
        let coins = holdings.launch.filter { (BigUInt($0.balance) ?? 0) > 0 }.map(Asset.coin)
        return (spot + coins).enumerated().sorted { a, b in
            let (x, y) = (a.element.valueUsd ?? 0, b.element.valueUsd ?? 0)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// What the tokens are worth together: the server's Spot and Launch totals, once both were read (`parts`); nil while
    /// one is missing, so a part is never passed off as the whole.
    static func tokensValue(_ holdings: StellarHoldings?) -> Double? {
        guard let holdings, holdings.parts["spot"] != "failed", holdings.parts["launch"] != "failed",
              let spot = holdings.totals.spot, let launch = holdings.totals.launch else { return nil }
        return spot + launch
    }

    /// The codes of held tokens with no price (an unverified classic asset): the total leaves them out, and says so.
    static func unpricedCodes(_ assets: [Asset]) -> [String] {
        assets.filter { $0.valueUsd == nil }.map(\.code)
    }

    /// The editions the account holds, in the server's order, v1's and v2's together.
    static func editions(_ holdings: StellarHoldings?) -> [Edition] {
        (holdings?.moments.editions ?? []).map(Edition.init)
    }

    /// `codes` as one list in the app's language ("XLM, USDC and EURC").
    static func codeList(_ codes: [String]) -> String {
        let list = ListFormatter()
        list.locale = L10n.locale
        return list.string(from: codes) ?? codes.joined(separator: ", ")
    }

    /// Whether an edition is of the retired v1 Moments contract (`v1Moments`, the pinned "moments" role): one with no
    /// contract named comes from a server older than contracts v2, which only had v1's.
    static func isRetired(_ edition: StellarEdition, v1Moments: [String]) -> Bool {
        guard let contract = edition.contract else { return true }
        return v1Moments.contains(contract)
    }

    /// Where an edition opens: a v2 Moment's page by its NFT contract, a retired v1 Moment by its number.
    static func destination(_ edition: StellarEdition, v1Moments: [String]) -> StellarDestination {
        if !isRetired(edition, v1Moments: v1Moments), let nft = edition.contract { return .momentV2(nft: nft) }
        return .moment(id: edition.momentId)
    }

    /// Whether each of the account's launches My Launchpad lists is of the retired v1 launchpad (generation 1), by token.
    static func retiredByToken(in mine: StellarMyLaunchpad) -> [String: Bool] {
        Dictionary((mine.held.map(\.launch) + mine.created.map(\.launch)).map { ($0.token, $0.generation == 1) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Of the held coins `held`, those of the retired v1 launchpad, by what was read of each (`read`, by token); a coin
    /// nothing was read of keeps what `known` said of it.
    static func retired(_ held: [String], read: [String: Bool], known: Set<String>) -> Set<String> {
        Set(held.filter { read[$0] ?? known.contains($0) })
    }

    /// Whether a history read of Portfolio's waits for the sign-in (a passkey account with no session): once a session
    /// comes back, Portfolio reads again.
    static func waitsForSignIn(_ store: LiteStore) -> Bool {
        [LitePart.portfolio, .activity].contains { store.status($0) == .needsSignIn }
    }

    // MARK: Saved figures

    /// Takes in the account before the screen's first frame: another account's figures go, and what was saved for this
    /// one when it was last read shows at once, each period said to be saved until its own read replaces it.
    func showSaved(owner: Address?, stellar: String?) {
        guard owner != self.owner || stellar != self.stellar else { return }
        clear()
        self.owner = owner
        self.stellar = stellar
        guard let owner, let stellar else { return }
        epoch = saved.epoch(for: owner)
        guard let file = saved.load(Saved.self, .portfolio, owner: owner)?.value, file.stellar == stellar else { return }
        let now = Date()
        for (raw, figures) in file.periods {
            guard let key = VolumePeriodKey(rawValue: raw), SavedScreens.isShowable(savedAt: figures.readAt, now: now) else { continue }
            savedFigures[key] = figures
        }
    }

    /// The account signed out of Stellar: its figures leave the screen (its saved file is erased by `StellarSaved.forget`),
    /// and anything read from now on is saved under a new guard.
    func forget() {
        clear()
        epoch = owner.map { saved.epoch(for: $0) }
    }

    private func clear() {
        savedFigures = [:]
        retiredCoins = []
        liveFigures = [:]
        retiredRead = false
    }

    /// Takes in the store's reads, by period, and saves them with what was saved for the periods not read since; dropped
    /// after a sign-out or an erase since the figures were first shown.
    func take(_ portfolios: [VolumePeriodKey: StellarPortfolio], now: Date = Date()) {
        var changed = false
        for (key, portfolio) in portfolios {
            let figures = Figures(portfolio, now: now)
            if liveFigures[key] != figures {
                liveFigures[key] = figures
                changed = true
            }
        }
        if changed { save() }
    }

    private func save() {
        guard let owner, let stellar, let epoch else { return }
        let periods = savedFigures.merging(liveFigures) { _, live in live }
        guard let newest = periods.values.map(\.readAt).max() else { return }
        let file = Saved(stellar: stellar, periods: Dictionary(uniqueKeysWithValues: periods.map { ($0.key.rawValue, $0.value) }))
        saved.save(file, .portfolio, owner: owner, savedAt: newest, epoch: epoch)
    }

    // MARK: Reads

    /// Portfolio's reads, side by side: the period's figures and activity (DyorHQ's history), the all-time figures (the Earn
    /// card's "Earned so far") and the holdings (a viewer read) unless already read and not `force`, and the words of the
    /// activity's rows. Then which held coins are of the retired
    /// v1 launchpad. A passkey account with no session gets `.needsSignIn` for the history, and nothing asks: the load
    /// after its sign-in reads the history it waited for.
    func load(_ store: LiteStore?, period: VolumePeriod, force: Bool) async {
        guard let store, let key = VolumePeriodKey(rawValue: period.rawValue) else { return }
        loads += 1
        defer { loads -= 1 }
        async let figures: Void = store.refreshPortfolio(key)
        async let lifetime: Void = readLifetime(store, besides: key, force: force)
        async let holdings: Void = readHoldings(store, force: force)
        async let words: Void = readActivity(store, force: force)
        _ = await (figures, lifetime, holdings, words)
        await readRetired(store, force: force)
        take(store.portfolio)
    }

    private func readHoldings(_ store: LiteStore, force: Bool) async {
        if force || store.holdings == nil { await store.refreshHoldings() }
    }

    /// The all-time figures beside another period's, unless already read and not `force`: the Earn card's "Earned so far"
    /// is the all-time Earn P&L. A settled action reads them again with the other periods read (`LiteStore`).
    private func readLifetime(_ store: LiteStore, besides key: VolumePeriodKey, force: Bool) async {
        if key != .all, force || store.portfolio[.all] == nil { await store.refreshPortfolio(.all) }
    }

    /// The account's activity with the details its rows are worded from (`StellarActivityPresenter`), in the app's
    /// language rather than the server's English: until it is read, every load asks again (after a sign-in, after a read
    /// that failed).
    private func readActivity(_ store: LiteStore, force: Bool) async {
        if force || store.status(.activity) != .read { await store.refreshActivity() }
    }

    /// Which held coins are of the retired v1 launchpad: once per session, and again on a pull. My Launchpad says it for
    /// the account's launches in one read; a coin it doesn't list, and every coin while it needs the sign-in (a passkey
    /// account in the public view), is read from its own launch page, a viewer read. A coin whose read failed keeps what
    /// was known of it, and is read again with the next load.
    private func readRetired(_ store: LiteStore, force: Bool) async {
        guard let held = store.holdings?.launch.map(\.token), !held.isEmpty, force || !retiredRead else { return }
        var read = (try? await store.myLaunchpad()).map(Self.retiredByToken) ?? [:]
        let unlisted = held.filter { read[$0] == nil }
        let pages = await withTaskGroup(of: (token: String, retired: Bool)?.self) { group in
            for token in unlisted {
                group.addTask { @MainActor in (try? await store.launchDetail(token)).map { (token: token, retired: $0.launch.generation == 1) } }
            }
            var pages: [String: Bool] = [:]
            for await page in group {
                if let page { pages[page.token] = page.retired }
            }
            return pages
        }
        read.merge(pages) { listed, _ in listed }
        retiredRead = held.allSatisfy { read[$0] != nil }
        let retired = Self.retired(held, read: read, known: retiredCoins)
        if retired != retiredCoins { retiredCoins = retired }
    }
}
#endif
