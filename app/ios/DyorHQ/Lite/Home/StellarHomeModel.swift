// Stellar Home's figures: the account's four parts, Total Volume, Top Tokens, and what Home saved when it last read
// them (docs/DESIGN-stellar-parity.md §8.2, §8.2.7, §3.9). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import BigInt
import DyorKit
import DyorLite
import Foundation
import StellarKit

/// Stellar Home's figures, kept as Monad's `HomeModel` keeps Monad's. The account's four parts, Spot, Earn, Launch and
/// Moments, come from one viewer read (`/v1/holdings`, through `LiteStore`), with or without a session, and each is
/// gated by DyorKit's `HomeReadState` (Earn in Perps' place): a figure from a part not read yet is nil, a placeholder on
/// screen, never "$0.00"; a part once read keeps its last good figures when a later read of it fails; the total waits
/// for all four. Total Volume is DyorHQ's history (`/v1/portfolio`), which needs a session.
///
/// What Home showed is saved for the account (`StellarSaved`, screen `.home`) and shown before Home's first frame, each
/// part said to be saved until its own read replaces it: after a relaunch, an expired session or the background, Home
/// opens on the account's figures, never on a prompt (decision 6). The Earn total is saved, its positions never are,
/// as on Monad. Sign-out erases the file (`StellarSaved.forget`) and the figures on screen (`forget`).
@MainActor
@Observable
final class StellarHomeModel {
    typealias Part = HomeReadState.Part

    /// Home's four parts as the balance card splits them, once each of them can be told (`HomeReadState.showsValue`).
    struct Split: Hashable {
        let spot: Double
        let earn: Double
        let launch: Double
        let moments: Double
        var total: Double { spot + earn + launch + moments }
    }

    /// A Moment the account holds editions of, as My Holdings lists it: one row per Moment, its editions counted.
    struct MomentHolding: Identifiable, Hashable {
        let momentId: Int
        /// The Moments contract that minted its editions.
        let contract: String?
        let title: String?
        /// Its picture: the poster of a video, else the photo.
        let image: String?
        let editions: Int
        /// Collecting, sold out or closed, from the Moment's board row when it was read; nil when it wasn't.
        let state: StellarMomentState?
        var id: String { "\(contract ?? "")-\(momentId)" }
    }

    /// Total Volume over a period, and when it was read.
    struct Volume: Codable, Equatable, Sendable {
        let usd: Double
        let readAt: Date
    }

    /// What Home saves for an account (`SavedScreens.Screen.home`): each part it had figures of, with when it was read,
    /// and Total Volume by period. Earn is its total only: its positions are read every time.
    struct Saved: Codable, Sendable {
        /// The Stellar account the figures are of: a file for another is never shown.
        var stellar: String
        var spot: [StellarHoldings.SpotHolding]?
        var launch: [StellarHoldings.LaunchHolding]?
        var editions: [StellarEdition]?
        var values: [Part: Double]
        var change: StellarHoldings.Change?
        var readAt: [Part: Date]
        var volumes: [VolumePeriodKey: Volume]
    }

    /// How often Home reads the account again while it is on screen and the app is active (Monad Home's rhythm).
    static let pollInterval: Duration = .seconds(30)

    /// The parts of `/v1/holdings` as Home reads them, each with the store's name for it: Earn in Perps' place.
    static let parts: [(part: Part, lite: LitePart)] = [(.spot, .spot), (.perps, .earn), (.launch, .launch), (.moments, .moments)]

    /// The registry, classic and contract assets in the account, as last read (zero balances included: `holdings`
    /// leaves them out).
    private(set) var spot: [StellarHoldings.SpotHolding] = []
    /// Earn's positions: read in this session only, never saved.
    private(set) var earn: [EarnPosition] = []
    private(set) var launch: [StellarHoldings.LaunchHolding] = []
    private(set) var editions: [StellarEdition] = []
    /// Each part's value in dollars, as the server totals it (Moments count as 0: editions have no market); a part with
    /// no total isn't in it.
    private(set) var values: [Part: Double] = [:]
    /// The account's 24h change, from the last read that answered for every part.
    private(set) var change: StellarHoldings.Change?
    /// How far each part has been read for the account (`HomeReadState`).
    private(set) var reads = HomeReadState()
    /// When a read that answered for every part landed: the header says how long ago.
    private(set) var updatedAt: Date?
    /// Total Volume as saved when the account was last read, by period: shown, said to be saved, until the period's own
    /// read lands (`LiteStore.portfolio`).
    private(set) var savedVolumes: [VolumePeriodKey: Volume] = [:]
    private var loads = 0

    /// When each part on screen was read: in this session, or for a part still showing what was saved, when that was.
    @ObservationIgnored private var readAt: [Part: Date] = [:]
    /// Total Volume read in this session, by period, for what Home saves.
    @ObservationIgnored private var liveVolumes: [VolumePeriodKey: Volume] = [:]
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

    /// A read of Home's own is under way (a poll, a pull, a Retry).
    var loading: Bool { loads > 0 }

    // MARK: Figures

    /// Spot's rows: what the account holds, the most valuable first (ties in the server's order).
    var holdings: [StellarHoldings.SpotHolding] {
        let held = spot.filter { (BigUInt($0.balance) ?? 0) > 0 }
        return held.enumerated().sorted { a, b in
            let (x, y) = (a.element.valueUsd ?? 0, b.element.valueUsd ?? 0)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// Each part's figure, nil until it can be told for the account (`HomeReadState.showsValue`).
    var spotValue: Double? { reads.showsValue(of: .spot) ? values[.spot] : nil }
    var earnValue: Double? { reads.showsValue(of: .perps) ? values[.perps] : nil }
    var launchValue: Double? { reads.showsValue(of: .launch) ? values[.launch] : nil }
    var momentsValue: Double? { reads.showsValue(of: .moments) ? values[.moments] : nil }
    /// Avail. Balance: what Spot holds (R23).
    var availableBalance: Double? { spotValue }
    /// In Use: what Earn has lent (R23).
    var inUse: Double? { earnValue }

    /// The four parts' figures, once every one of them can be told: the allocation ring's shares and the total.
    var split: Split? {
        guard let spot = spotValue, let earn = earnValue, let launch = launchValue, let moments = momentsValue else { return nil }
        return Split(spot: spot, earn: earn, launch: launch, moments: moments)
    }

    /// Everything the account holds: nil until every part is read for it, so a total short of one is never shown.
    var total: Double? { split?.total }

    /// The 24h change in percent (1.23 for +1.23%), with the total only.
    var change24hPercent: Double? { total == nil ? nil : StellarPercent(change?.pct)?.value }

    /// The 24h change in dollars, with the total only.
    var changeAmount: Double { total == nil ? 0 : change?.usd ?? 0 }

    /// Whether the account holds anything at all in a part read: the allocation ring shows for it at $0.
    var hasHoldings: Bool { !holdings.isEmpty || !earn.isEmpty || !launch.isEmpty || !editions.isEmpty }

    /// When the oldest part still showing what was saved was read: Home says it ("Updated 3 min ago") until every part on
    /// screen was read in this session, and then this is nil.
    var savedAt: Date? { Part.allCases.filter { reads.isSaved($0) }.compactMap { readAt[$0] }.min() }

    /// The header's warning: a part whose last read failed (said to show the last figures read when it has some), else
    /// markets that couldn't be read at all.
    func error(store: LiteStore?, markets: LitePublicReads?) -> String? {
        error(statuses: Self.statuses(store), marketsFailure: markets.flatMap { $0.markets.isEmpty ? $0.marketsError : nil })
    }

    func error(statuses: [LitePart: LiteReadStatus], marketsFailure: String?) -> String? {
        for (part, lite) in Self.parts where statuses[lite] == .failed {
            return reads.hasFigures(part) ? tr("Your balances couldn't be read just now — showing the last ones read.") : tr(Self.unreadMessage(part))
        }
        return marketsFailure
    }

    /// How the store's last read of each holdings part went.
    static func statuses(_ store: LiteStore?) -> [LitePart: LiteReadStatus] {
        guard let store else { return [:] }
        return Dictionary(uniqueKeysWithValues: parts.map { ($0.lite, store.status($0.lite)) })
    }

    /// What a part's tab says when no read of it has answered for the account and the last one failed; the header says
    /// it too.
    static func unreadMessage(_ part: Part) -> LocalizedStringResource {
        switch part {
        case .spot: return LocalizedStringResource("Your Stellar balances couldn't be read just now.", table: "StellarHome", comment: "Stellar Home, My Holdings' Spot tab before anything was read: the account's balances or their prices couldn't be read. A Retry button follows. Stellar is never translated")
        case .perps: return LocalizedStringResource("Your Earn positions couldn't be read just now.", table: "StellarHome", comment: "Stellar Home, My Holdings' Earn tab before anything was read: what the account lends on Blend couldn't be read. A Retry button follows")
        case .launch: return LocalizedStringResource("Your launch coins couldn't be read just now.")
        case .moments: return LocalizedStringResource("Your Moments couldn't be read just now.")
        }
    }

    /// The account's Moments, one row per Moment in the order the server lists the editions, with each one's state from
    /// the Moments board read (`LiteStore.moments`) at `now`.
    static func momentHoldings(_ editions: [StellarEdition], board: [StellarMoment], now: Date) -> [MomentHolding] {
        var order: [String] = []
        var groups: [String: [StellarEdition]] = [:]
        for edition in editions {
            let key = "\(edition.contract ?? "")-\(edition.momentId)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(edition)
        }
        return order.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            let moment = board.first { $0.id == first.momentId }
            let image = group.lazy.compactMap { $0.posterUrl ?? ($0.mediaType == "video" ? nil : $0.mediaUrl) }.first
                ?? moment?.posterUrl ?? (moment?.mediaType == "video" ? nil : moment?.mediaUrl)
            return MomentHolding(momentId: first.momentId, contract: first.contract, title: group.lazy.compactMap(\.title).first ?? moment?.title,
                                 image: image, editions: group.count, state: moment.map { StellarMomentState($0, now: now) })
        }
    }

    /// Top Tokens' tab: Monad's rules (`StellarMarketRanking`) over the markets read, without a test asset or a look-alike
    /// (the server lists neither; a row that says it is one never shows).
    static func topTokens(_ rows: [StellarMarketRow], tab: HomeTokenTab) -> [StellarMarketRow] {
        let listed = rows.filter { !$0.badges.contains("testAsset") && !$0.badges.contains("lookAlike") }
        return StellarMarketRanking.rows(listed, tab: StellarMarketRanking.Tab(rawValue: tab.rawValue) ?? .popular)
    }

    // MARK: Saved figures

    /// Takes in the account before Home's first frame: another account's figures go, and what was saved for this one
    /// when it was last read shows at once, each part said to be saved until its own read replaces it.
    func showSaved(owner: Address?, stellar: String?) {
        guard owner != self.owner || stellar != self.stellar else { return }
        clear()
        self.owner = owner
        self.stellar = stellar
        guard let owner, let stellar else { return }
        epoch = saved.epoch(for: owner)
        restore(owner: owner, stellar: stellar)
    }

    /// The account signed out of Stellar: its figures leave the screen (its saved file is erased by `StellarSaved.forget`),
    /// and anything read from now on is saved under a new guard.
    func forget() {
        clear()
        epoch = owner.map { saved.epoch(for: $0) }
    }

    private func clear() {
        spot = []; earn = []; launch = []; editions = []; values = [:]; change = nil
        reads = HomeReadState(); updatedAt = nil; savedVolumes = [:]
        readAt = [:]; liveVolumes = [:]
    }

    /// What Home saved for the account, shown at once: each part read under a day ago, said to be saved
    /// (`HomeReadState.showSaved`, `savedAt`), and Total Volume by period.
    private func restore(owner: Address, stellar: String) {
        guard let file = saved.load(Saved.self, .home, owner: owner)?.value, file.stellar == stellar else { return }
        let now = Date()
        var parts: Set<Part> = []
        for (part, at) in file.readAt where SavedScreens.isShowable(savedAt: at, now: now) {
            switch part {
            case .spot:
                guard let rows = file.spot else { continue }
                spot = rows
            case .perps:
                guard file.values[.perps] != nil else { continue }
            case .launch:
                guard let rows = file.launch else { continue }
                launch = rows
            case .moments:
                guard let rows = file.editions else { continue }
                editions = rows
            }
            values[part] = file.values[part]
            parts.insert(part)
            readAt[part] = min(at, now)
        }
        reads.showSaved(parts)
        if parts.count == Part.allCases.count { change = file.change }
        savedVolumes = file.volumes.filter { SavedScreens.isShowable(savedAt: $0.value.readAt, now: now) }
    }

    /// Saves each part Home has figures of, with when it was read (a part still showing the saved figures keeps its first
    /// time), and Total Volume; dropped after a sign-out or an erase since the figures were first shown.
    private func save() {
        guard let owner, let stellar, let epoch else { return }
        let times = readAt.filter { reads.hasFigures($0.key) }
        let volumes = savedVolumes.merging(liveVolumes) { _, live in live }
        guard let newest = (Array(times.values) + volumes.values.map(\.readAt)).max() else { return }
        let file = Saved(stellar: stellar, spot: times[.spot] == nil ? nil : spot, launch: times[.launch] == nil ? nil : launch,
                         editions: times[.moments] == nil ? nil : editions, values: values.filter { times[$0.key] != nil },
                         change: times.count == Part.allCases.count ? change : nil, readAt: times, volumes: volumes)
        saved.save(file, .home, owner: owner, savedAt: newest, epoch: epoch)
    }

    // MARK: Reads

    /// Takes in the store's last holdings read: each part it read replaces that part's figures; a part whose read failed
    /// keeps what it showed, and says so. Called after Home's own reads and whenever the store's holdings change (the
    /// root's read, the read after a settled action).
    func sync(from store: LiteStore, now: Date = Date()) {
        guard store.address == stellar else { return }
        take(store.holdings, statuses: Self.statuses(store), now: now)
    }

    /// Takes in one state of the holdings read: `holdings` the last answer, `statuses` how each part's last read went.
    func take(_ holdings: StellarHoldings?, statuses: [LitePart: LiteReadStatus], now: Date = Date()) {
        let at = holdings.flatMap { StellarFormat.date($0.asOf) }.map { min($0, now) } ?? now
        var answeredAll = holdings != nil
        for (part, lite) in Self.parts {
            switch statuses[lite] ?? .unread {
            case .read:
                guard let holdings else { continue }
                take(part, from: holdings)
                record(part, answered: true, at: at)
            case .failed:
                record(part, answered: false, at: at)
                answeredAll = false
            case .unread, .needsSignIn:
                answeredAll = false
            }
        }
        if answeredAll, let holdings {
            if change != holdings.change24h { change = holdings.change24h }
            if updatedAt != at { updatedAt = at }
        }
        save()
    }

    /// Takes in the Total Volume the store read, by period, for what Home saves.
    func syncVolume(from store: LiteStore, now: Date = Date()) {
        guard store.address == stellar else { return }
        takeVolumes(store.portfolio, now: now)
    }

    /// Takes in Portfolio's reads, by period: Total Volume, for what Home saves.
    func takeVolumes(_ portfolios: [VolumePeriodKey: StellarPortfolio], now: Date = Date()) {
        var changed = false
        for (key, portfolio) in portfolios {
            let volume = Volume(usd: portfolio.totals.volume, readAt: StellarFormat.date(portfolio.asOf).map { min($0, now) } ?? now)
            if liveVolumes[key] != volume {
                liveVolumes[key] = volume
                changed = true
            }
        }
        if changed { save() }
    }

    /// Home's own reads, side by side: Top Tokens (public, with or without a session), and once Home is ready the account
    /// and its holdings (viewer reads, with or without a session). `resume`: a paused or idle session is looked at again
    /// first, never with a prompt (a pull).
    func load(_ session: LiteSession, resume: Bool = false) async {
        loads += 1
        defer { loads -= 1 }
        if resume, session.home != .ready { await session.refreshHome() }
        async let markets: Void = session.publicReads.refreshMarkets()
        if session.home == .ready, let store = session.store {
            async let account: Void = store.refreshAccount()
            async let holdings: Void = store.refreshHoldings()
            _ = await (account, holdings)
            sync(from: store)
        }
        await markets
    }

    /// Total Volume over `period` (DyorHQ's history: a session read; a passkey account in the public view gets
    /// `.needsSignIn` and nothing asks).
    func loadVolume(_ store: LiteStore?, period: VolumePeriod) async {
        guard let store, let key = VolumePeriodKey(rawValue: period.rawValue) else { return }
        await store.refreshPortfolio(key)
        syncVolume(from: store)
    }

    /// Reads Home again every 30 s while it is on screen and the app is active, in place: what was read stays until the
    /// new read replaces it. The first read waits for the first tick unless nothing was read yet.
    func poll(_ session: LiteSession) async {
        if session.publicReads.markets.isEmpty || (session.home == .ready && session.store?.status(.spot) == .unread) {
            await load(session)
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return }
            await load(session)
        }
    }

    /// One read of `part` answered, or failed (`HomeReadState.record`); set only when it changed, so an unchanged refresh
    /// doesn't redraw what follows it. An answer is dated, for what Home saves.
    private func record(_ part: Part, answered: Bool, at: Date) {
        var next = reads
        next.record(part, answered: answered)
        if next != reads { reads = next }
        if answered { readAt[part] = at }
    }

    /// `part`'s figures from a read that answered for it, set only where they changed.
    private func take(_ part: Part, from holdings: StellarHoldings) {
        let value: Double?
        switch part {
        case .spot:
            if spot != holdings.spot { spot = holdings.spot }
            value = holdings.totals.spot
        case .perps:
            if earn != holdings.earn { earn = holdings.earn }
            value = holdings.totals.earn
        case .launch:
            if launch != holdings.launch { launch = holdings.launch }
            value = holdings.totals.launch
        case .moments:
            if editions != holdings.moments.editions { editions = holdings.moments.editions }
            value = holdings.totals.moments
        }
        if values[part] != value { values[part] = value }
    }
}
#endif
