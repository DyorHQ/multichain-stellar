// Stellar copy of ios/DyorHQ/Moments/MomentsPortfolioView.swift MomentsPortfolioView (42cd8c7 sha256:c02a3b42d18e)
// Stellar copy of ios/DyorHQ/Moments/MomentsPortfolioView.swift PortfolioRowView (42cd8c7 sha256:e41c4e536432)
// My Moments on Stellar (docs/DESIGN-stellar-parity.md §8.11.5; docs/DESIGN-stellar-contracts-v2.md §21). Internal builds
// only (STELLAR_LITE).
#if STELLAR_LITE
import BigInt
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// What My Moments asks its opener to open over the board: a v2 Moment as My Moments knows it, or a retired v1 Moment by
/// the contract that minted it (when known) and its number there.
enum StellarMomentOpening {
    case moment(StellarMomentListingV2)
    case retired(contract: String?, id: Int)
}

/// My Moments: the account's totals across both generations (editions, Moments, spent and earned per quote), its coins
/// across every v2 Moment (promised, claimable now, still vesting, claimed) with one Claim All for what has vested, its
/// editions with their way into Freighter and the Moments it published; then the retired v1 Moments as legacy editions.
/// Coins and editions are viewer reads, shown with or without a session; the totals, the Moments published and the
/// retired history are DyorHQ's (decision 6): a passkey account with no session gets "Sign in with your passkey" instead
/// of an error, and nothing prompts until it is tapped.
struct StellarMomentsPortfolioView: View {
    let onOpen: (StellarMomentOpening) -> Void
    @Environment(\.stellarSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model = StellarMyMomentsModel()
    @State private var showClaimAll = false
    @State private var freighter: StellarFreighterEdition?

    private var claimAll: [StellarMyMomentsModel.Coins] { model.claimAllBatch }

    var body: some View {
        NavigationStack {
            List {
                historySection
                if model.live != nil || model.liveError != nil {
                    coinsSection
                    editionsSection
                    publishedSection
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your Moments…").foregroundStyle(.secondary) }
                }
                if let liveError = model.liveError { errorRow(liveError) }
                if model.isEmpty {
                    ContentUnavailableView {
                        Label("No Moments Yet", systemImage: "camera.aperture")
                    } description: {
                        Paragraph(LocalizedStringResource("Collect a Moment and it shows up here.", table: "StellarMomentsBoard", comment: "My Moments on Stellar with no Moment collected or published yet"))
                    } actions: {
                        Button("Browse Moments") { Haptics.tap(); dismiss() }
                    }
                }
                retiredSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("My Moments"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            // Read on opening, and again once a passkey account signs in from the sign-in row (the history needs it).
            .task(id: session?.access == .session) { await load() }
            .sheet(item: $freighter) { StellarFreighterSheet(edition: $0) }
            .sheet(isPresented: $showClaimAll) { claimAllSheet }
        }
    }

    // MARK: Totals

    /// Both generations' totals, as GET /v1/moments/v2/mine and GET /v1/moments/mine state them: DyorHQ's history.
    @ViewBuilder private var historySection: some View {
        switch model.history {
        case .needsSignIn:
            Section { StellarSignInRow() }
        case .failed(let failure):
            Section { errorRow(failure) }
        case .read(let totals) where totals.hasAny:
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    tile(Text("Editions"), "\(totals.editions)",
                         Text("in your account", tableName: "StellarMomentsBoard", comment: "[tight] My Moments tile on Stellar, under the number of Editions"))
                    tile(Text("Moments"), "\(totals.moments)",
                         Text("collected", tableName: "StellarMomentsBoard", comment: "[tight] My Moments tile on Stellar, under the number of Moments the editions are from"))
                    tile(Text("Spent", tableName: "StellarMomentsBoard", comment: "[tight] My Moments tile on Stellar: what the account paid collecting editions"), totals.spent,
                         Text("collecting editions", tableName: "StellarMomentsBoard", comment: "[tight] My Moments tile on Stellar, under the amount Spent"))
                    tile(Text("Earned", tableName: "StellarMomentsBoard", comment: "[tight] My Moments tile on Stellar: what the account's Moments earned it"), totals.earned,
                         Text("from your Moments", tableName: "StellarMomentsBoard", comment: "[tight] My Moments tile on Stellar, under the amount Earned"))
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
        case .read, .unread, .absent:
            EmptyView()
        }
    }

    // MARK: Coins

    @ViewBuilder private var coinsSection: some View {
        let totals = model.coinTotals
        if totals.hasAny {
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    tile(Text("Pending"), StellarFormat.units(totals.pending.description, compact: true), Text("promised, not graduated yet"))
                    tile(Text("Claimable now"), StellarFormat.units(totals.claimable.description, compact: true), Text("vested and unclaimed"),
                         tint: totals.claimable > 0 ? .brand : .primary)
                    tile(Text("Still vesting"), StellarFormat.units(totals.vesting.description, compact: true),
                         Text("unlocks as it vests", tableName: "StellarMomentsBoard", comment: "[tight] My Moments tile on Stellar, under the amount of Still vesting: coins that unlock over time"))
                    tile(Text("Claimed"), StellarFormat.units(totals.claimed.description, compact: true),
                         Text("already in your account", tableName: "StellarMomentsBoard", comment: "[tight] My Moments tile on Stellar, under the amount of Claimed: coins already claimed into the account"))
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                if totals.claimable > 0 {
                    Button("Claim All", systemImage: "arrow.down.circle.fill") { Haptics.tap(); showClaimAll = true }
                        .fontWeight(.semibold)
                        .disabled(session?.canSign != true || claimAll.isEmpty)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Paragraph(LocalizedStringResource("Coins across every Moment you collected or published. They vest from graduation; claim what has vested here or on each Moment's page.", table: "StellarMomentsBoard", comment: "Under the coin tiles of My Moments on Stellar"))
                    if model.claimableMoments > claimAll.count {
                        Paragraph(LocalizedStringResource("Claim All takes up to \(claimAll.count) Moments at a time; claim again for the rest.", table: "StellarMomentsBoard", comment: "Under the coin tiles of My Moments on Stellar, when more Moments have coins to claim than one transaction takes. The number is how many one claim takes (20)"))
                    }
                }
            }
        }
    }

    /// `title` and `subtitle` are `Text`s so their keys carry a translator's note: both are tight.
    private func tile(_ title: Text, _ value: String, _ subtitle: Text, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            title.font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.headline).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            subtitle.font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var claimAllSheet: some View {
        let batch = claimAll
        return StellarConfirmationSheet(
            title: "Claim All", confirmTitle: "Claim All",
            build: {
                guard let store = session?.store else { throw LiteAPIError.notSignedIn }
                return try await MomentsV2Store(store: store).claimAllPlan(nfts: batch.map(\.nft), maxClaimIds: model.maxClaimIds, title: tr("Claim All"))
            },
            onDone: { Task { await load() } }, onCompleted: { _ in Task { await load() } }
        ) {
            ForEach(batch) { coins in
                DetailRow(Text(verbatim: coins.label), Text(verbatim: StellarMomentText.coins(coins.claimable.description, symbol: nil)))
            }
        }
    }

    // MARK: Editions and published Moments

    @ViewBuilder private var editionsSection: some View {
        let editions = model.editions
        if !editions.isEmpty {
            Section {
                ForEach(editions) { edition in
                    Button { Haptics.tap(); onOpen(.moment(StellarMomentListingV2(edition.moment))) } label: {
                        StellarEditionRow(name: edition.name, image: edition.moment.image, tokenId: edition.tokenId,
                                          price: StellarMomentText.amount(edition.moment.price, code: edition.moment.quoteCode))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) { freighterButton(edition.freighter) }
                    .contextMenu { freighterButton(edition.freighter) }
                }
            } header: {
                Text("Your Editions", tableName: "StellarMomentsBoard", comment: "A section of My Moments on Stellar: the Moment editions (NFTs) the account holds")
            } footer: {
                Paragraph(LocalizedStringResource("Collected on Stellar. OpenSea doesn't list Stellar; add an edition to Freighter to see it there.", table: "StellarMomentsBoard", comment: "Under the editions of My Moments on Stellar. OpenSea, Stellar and Freighter are never translated"))
            }
        }
    }

    /// View in Freighter, for a swipe and a context menu; nothing when the edition's contract isn't a contract address.
    @ViewBuilder private func freighterButton(_ edition: StellarFreighterEdition?) -> some View {
        if let edition {
            Button {
                Haptics.tap()
                freighter = edition
            } label: {
                Label { Text("View in Freighter", tableName: "StellarMomentsBoard", comment: "A swipe and menu action on a Moment edition in My Moments on Stellar: how to see it in Freighter. Freighter is never translated") } icon: { Image(systemName: "wallet.bifold") }
            }
            .tint(.brand)
        }
    }

    @ViewBuilder private var publishedSection: some View {
        let created = model.live?.created ?? []
        if !created.isEmpty {
            Section {
                ForEach(created) { published in
                    Button { Haptics.tap(); onOpen(.moment(StellarMomentListingV2(published.moment))) } label: {
                        StellarPublishedRow(name: StellarMomentBoard.title(published.moment) ?? published.moment.name, image: published.moment.image,
                                            collected: Text("\(published.moment.minted) collected", tableName: "StellarMomentsBoard", comment: "A Moment the account published, in My Moments on Stellar: how many editions were collected"),
                                            earned: StellarMomentText.amount(published.proceeds, code: published.moment.quoteCode))
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Published by You", tableName: "StellarMomentsBoard", comment: "A section of My Moments on Stellar: the Moments the account published")
            }
        }
    }

    // MARK: Retired

    /// The retired v1 Moments: the account's legacy editions and the Moments it published there (GET /v1/moments/mine),
    /// DyorHQ's history. Their totals are in the tiles.
    @ViewBuilder private var retiredSection: some View {
        if case .read(let mine) = model.legacy, !mine.collected.isEmpty || !mine.created.isEmpty {
            Section {
                ForEach(mine.collected) { edition in
                    Button { Haptics.tap(); onOpen(.retired(contract: edition.contract, id: edition.momentId)) } label: {
                        StellarEditionRow(name: StellarMomentBoard.title(edition.moment) ?? "", image: edition.moment.posterUrl ?? edition.moment.mediaUrl, tokenId: edition.tokenId,
                                          price: StellarMomentText.amount(edition.moment.price, code: StellarMyMomentsModel.code(edition.moment)))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) { freighterButton(StellarMyMomentsModel.freighter(edition)) }
                    .contextMenu { freighterButton(StellarMyMomentsModel.freighter(edition)) }
                }
                ForEach(mine.created) { published in
                    let m = published.moment
                    Button { Haptics.tap(); onOpen(.retired(contract: nil, id: m.id)) } label: {
                        StellarPublishedRow(name: StellarMomentBoard.title(m) ?? "", image: m.posterUrl ?? m.mediaUrl,
                                            collected: m.maxEditions > 0
                                                ? Text("\(m.minted) of \(m.maxEditions) collected", tableName: "StellarMomentsBoard", comment: "A retired Moment the account published, in My Moments on Stellar: editions collected of its edition size")
                                                : Text("\(m.minted) collected", tableName: "StellarMomentsBoard"),
                                            earned: StellarMomentText.amount(published.proceeds, code: StellarMyMomentsModel.code(m)))
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Retired", tableName: "StellarMomentsBoard")
            } footer: {
                Paragraph(LocalizedStringResource("Legacy editions from DyorHQ's first Stellar Moments contract: view them and add them to Freighter. Collecting is closed.", table: "StellarMomentsBoard", comment: "Under the Retired section of My Moments on Stellar. DyorHQ, Stellar and Freighter are never translated"))
            }
        }
    }

    /// A part's failed read, as the screens word it, with Retry.
    private func errorRow(_ failure: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            InlineError(message: failure)
            Spacer(minLength: 8)
            Button("Retry") { Task { await load() } }.font(.footnote.weight(.semibold))
        }
    }

    private func load() async {
        guard let session else { return }
        await model.load(session)
    }
}

/// An edition row (MomentsPortfolioView's row, for Stellar editions): the art, the Moment's name, its edition number and
/// the price it was collected at.
private struct StellarEditionRow: View {
    let name: String
    let image: String?
    let tokenId: Int
    let price: String

    var body: some View {
        HStack(spacing: 12) {
            StellarMomentArtwork(image: image, name: name)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("Edition #\(String(tokenId))", tableName: "StellarMomentsBoard", comment: "A Moment edition in My Moments on Stellar: its number (its NFT token id)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            Text(verbatim: price).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A Moment the account published: the art, its name, how many editions were collected and what it earned.
private struct StellarPublishedRow: View {
    let name: String
    let image: String?
    let collected: Text
    /// What it earned, with its asset's code.
    let earned: String

    var body: some View {
        HStack(spacing: 12) {
            StellarMomentArtwork(image: image, name: name)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name).font(.subheadline.weight(.semibold)).lineLimit(1)
                collected.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: earned).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1)
                Text("Earned", tableName: "StellarMomentsBoard").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// My Moments' reads, all through `MomentsV2Store` and `LiteStore`: the account's v2 Moments (GET /v1/moments/v2/mine
/// with a session, else its editions and coins from GET /v1/moments/v2/owned, a viewer read), their vesting, the Moments
/// terms, and the retired v1 history (GET /v1/moments/mine).
@Observable
@MainActor
final class StellarMyMomentsModel {
    /// The account's v2 Moments as last read.
    struct Live: Equatable {
        /// The Moments it holds editions of or was promised coins in, newest first.
        var holdings: [StellarMomentHoldingV2]
        /// The Moments it published, newest first, with their proceeds; empty without a session.
        var created: [StellarMyMomentsV2.Created]
        /// Its coins in each Moment, by NFT address, where they could be read.
        var vesting: [String: StellarMomentVestingV2]
    }

    /// An edition the account holds, with its Moment.
    struct Edition: Identifiable {
        let moment: StellarMomentRowV2
        let tokenId: Int
        var id: String { "\(moment.nft)#\(tokenId)" }
        var name: String { StellarMomentBoard.title(moment) ?? moment.name }

        /// The edition as Freighter adds it: the Moment's own NFT contract and its edition number.
        var freighter: StellarFreighterEdition? {
            StellarAccountID(moment.nft).map { StellarFreighterEdition(contract: $0, tokenId: tokenId, name: name, image: moment.image, isVideo: moment.isVideo) }
        }
    }

    /// The account's coins in one Moment, in the coin's base units.
    struct Coins: Identifiable, Equatable {
        let nft: String
        /// "$DUSK", else the Moment's name.
        let label: String
        var pending: BigUInt = 0
        var claimable: BigUInt = 0
        var vesting: BigUInt = 0
        var claimed: BigUInt = 0
        var id: String { nft }
    }

    /// The coins across every Moment.
    struct CoinTotals: Equatable {
        var pending: BigUInt = 0
        var claimable: BigUInt = 0
        var vesting: BigUInt = 0
        var claimed: BigUInt = 0
        var hasAny: Bool { pending > 0 || claimable > 0 || vesting > 0 || claimed > 0 }
    }

    /// The account's totals across both generations, as GET /v1/moments/v2/mine and GET /v1/moments/mine state them:
    /// editions held and the Moments they are from, and what it spent collecting and earned publishing, per quote asset.
    struct HistoryTotals: Equatable {
        var editions = 0
        var moments = 0
        /// Base units, by quote asset id ("XLM", "USDC").
        var spentByQuote: [String: BigUInt] = [:]
        var earnedByQuote: [String: BigUInt] = [:]

        init(v2: StellarMyMomentsV2.Totals?, v1: StellarMomentsMine.Totals?) {
            if let v2 { add(editions: v2.editions, moments: v2.moments, spent: v2.spentByQuote, earned: v2.earnedByQuote) }
            if let v1 { add(editions: v1.editions, moments: v1.moments, spent: v1.spentByQuote, earned: v1.earnedByQuote) }
        }

        /// "30 USDC · 12.5 XLM", or "0".
        var spent: String { Self.written(spentByQuote) }
        var earned: String { Self.written(earnedByQuote) }
        var hasAny: Bool { editions > 0 || moments > 0 || spentByQuote.values.contains { $0 > 0 } || earnedByQuote.values.contains { $0 > 0 } }

        private mutating func add(editions: Int, moments: Int, spent: [String: String], earned: [String: String]) {
            self.editions += editions
            self.moments += moments
            for (quote, units) in spent { spentByQuote[quote, default: 0] += BigUInt(units) ?? 0 }
            for (quote, units) in earned { earnedByQuote[quote, default: 0] += BigUInt(units) ?? 0 }
        }

        /// Amounts by quote asset id ("XLM", "USDC", or a contract the API doesn't know, shortened), in the order of the
        /// ids; "0" when there are none.
        static func written(_ byQuote: [String: BigUInt]) -> String {
            let parts = byQuote.sorted { $0.key < $1.key }.filter { $0.value > 0 }
                .map { StellarMomentText.amount($0.value.description, code: StellarAccountID($0.key)?.short ?? $0.key) }
            return parts.isEmpty ? "0" : parts.joined(separator: " · ")
        }
    }

    /// How a history read (DyorHQ's, a session's) last went.
    enum HistoryRead<Value: Equatable>: Equatable {
        case unread
        case read(Value)
        /// A passkey account with no session: the screen offers its passkey (`StellarSignInRow`) and asks nothing.
        case needsSignIn
        case failed(String)
        /// The network has no such Moments (no v2 contract pinned, or never a v1 one): nothing to read.
        case absent
    }

    private(set) var live: Live?
    private(set) var liveError: String?
    /// GET /v1/moments/v2/mine.
    private(set) var mineV2: HistoryRead<StellarMyMomentsV2> = .unread
    /// GET /v1/moments/mine: the retired history.
    private(set) var legacy: HistoryRead<StellarMomentsMine> = .unread
    /// The Moments a Claim All takes at once (the terms' `maxClaimIds`).
    private(set) var maxClaimIds = StellarMyMomentsModel.defaultMaxClaimIds

    /// Claim All's batch when the terms couldn't be read: the contract's own limit.
    static let defaultMaxClaimIds = 20

    /// Both histories as the tiles show them: their totals once both are read (or absent), else why not.
    var history: HistoryRead<HistoryTotals> { Self.history(v2: mineV2, v1: legacy) }

    /// Every edition the account holds, Moment by Moment, newest Moment first.
    var editions: [Edition] {
        (live?.holdings ?? []).flatMap { holding in holding.editions.sorted().map { Edition(moment: holding.moment, tokenId: $0) } }
    }

    /// The account's coins, Moment by Moment.
    var coins: [Coins] { live.map(Self.coins) ?? [] }

    var coinTotals: CoinTotals { Self.totals(coins) }

    /// How many Moments have coins to claim now.
    var claimableMoments: Int { coins.filter { $0.claimable > 0 }.count }

    /// What one Claim All takes: the Moments with the most to claim, up to `maxClaimIds`.
    var claimAllBatch: [Coins] { Self.batch(coins, max: maxClaimIds) }

    /// Nothing read shows any Moment: no v2 stake, nothing published and no retired history.
    var isEmpty: Bool {
        guard let live, live.holdings.isEmpty, live.created.isEmpty else { return false }
        switch (mineV2, legacy) {
        case (.read, .read(let mine)), (.absent, .read(let mine)): return mine.collected.isEmpty && mine.created.isEmpty
        case (.read, .absent), (.absent, .absent): return true
        default: return false
        }
    }

    /// Everything on the screen, read again side by side: the v2 Moments and the retired history.
    func load(_ session: LiteSession) async {
        guard let store = session.store else { return }
        async let liveRead: () = loadLive(session, store: store)
        async let legacyRead: () = loadLegacy(store)
        _ = await (liveRead, legacyRead)
    }

    private func loadLive(_ session: LiteSession, store: LiteStore) async {
        guard StellarMomentsBoardModel.isDeployed(session) else {
            live = Live(holdings: [], created: [], vesting: [:])
            mineV2 = .absent
            return
        }
        let moments = MomentsV2Store(store: store)
        async let terms = try? moments.economics()
        async let mineRead = Self.result { try await moments.mine() }
        async let ownedRead = Self.result { try await moments.owned() }
        let (mine, owned) = await (mineRead, ownedRead)
        guard !Task.isCancelled else { return }
        switch mine {
        case .success(let read): mineV2 = .read(read)
        case .failure(let error): mineV2 = Self.failed(error, store: store)
        }
        // The session's view when it is held (what each collect paid included), else the account's public view.
        let holdings: [StellarMomentHoldingV2]
        switch (mine, owned) {
        case (.success(let read), _): holdings = read.collected
        case (_, .success(let read)): holdings = read.moments
        case (_, .failure(let error)):
            liveError = LiteErrorText.describe(error)
            return
        }
        let created = (try? mine.get())?.created ?? []
        let vesting = await Self.vesting(of: Self.vestingNFTs(holdings: holdings, created: created.map(\.moment)), moments: moments)
        guard !Task.isCancelled else { return }
        let read = Live(holdings: holdings, created: created, vesting: vesting)
        if live != read { live = read }
        liveError = nil
        if let limit = (await terms)?.maxClaimIds, limit > 0 { maxClaimIds = limit }
    }

    private func loadLegacy(_ store: LiteStore) async {
        do {
            legacy = .read(try await store.myMoments())
        } catch let error as LiteAPIError where error.code == "not_deployed" {
            legacy = .absent
        } catch {
            guard !Task.isCancelled else { return }
            legacy = Self.failed(error, store: store)
        }
    }

    /// A history read that failed: the sign-in a passkey account with no session is offered, or the failure.
    private static func failed<Value: Equatable>(_ error: Error, store: LiteStore) -> HistoryRead<Value> {
        if case LiteAPIError.notSignedIn = error, store.status(.myMoments) == .needsSignIn { return .needsSignIn }
        return .failed(LiteErrorText.describe(error))
    }

    private static func result<Value>(_ read: () async throws -> Value) async -> Result<Value, any Error> {
        do { return .success(try await read()) } catch { return .failure(error) }
    }

    /// Both histories as one: the sign-in when either needs it, the first failure, or the totals once both answered.
    static func history(v2: HistoryRead<StellarMyMomentsV2>, v1: HistoryRead<StellarMomentsMine>) -> HistoryRead<HistoryTotals> {
        switch (v2, v1) {
        case (.needsSignIn, _), (_, .needsSignIn): return .needsSignIn
        case (.failed(let failure), _), (_, .failed(let failure)): return .failed(failure)
        case (.unread, _), (_, .unread): return .unread
        default:
            let mine: StellarMyMomentsV2? = if case .read(let read) = v2 { read } else { nil }
            let legacy: StellarMomentsMine? = if case .read(let read) = v1 { read } else { nil }
            return .read(HistoryTotals(v2: mine?.totals, v1: legacy?.totals))
        }
    }

    /// The Moments whose coins the account is owed, as a collector or as their creator: none of an expired Moment,
    /// whose coins never exist.
    static func vestingNFTs(holdings: [StellarMomentHoldingV2], created: [StellarMomentRowV2]) -> [String] {
        var nfts: [String] = []
        for holding in holdings where holding.moment.state != "expired" && (BigUInt(holding.entitlement) ?? 0) > 0 && !nfts.contains(holding.moment.nft) {
            nfts.append(holding.moment.nft)
        }
        for moment in created where moment.state != "expired" && moment.creatorAllocBps > 0 && !nfts.contains(moment.nft) {
            nfts.append(moment.nft)
        }
        return nfts
    }

    /// Each Moment's vesting for the account (a viewer read), side by side; a Moment whose read fails is left out.
    private static func vesting(of nfts: [String], moments: MomentsV2Store) async -> [String: StellarMomentVestingV2] {
        var out: [String: StellarMomentVestingV2] = [:]
        await withTaskGroup(of: (String, StellarMomentVestingV2?).self) { group in
            for nft in nfts { group.addTask { (nft, try? await moments.vesting(nft)) } }
            for await (nft, vesting) in group { if let vesting { out[nft] = vesting } }
        }
        return out
    }

    /// The account's coins Moment by Moment: before graduation, what it was promised (pending); once graduated, what it
    /// can claim, what is still vesting and what it claimed, from the Moment's vesting. A Moment whose vesting couldn't
    /// be read counts its promised coins as pending until it graduates, and is left out after.
    static func coins(_ live: Live) -> [Coins] {
        var rows: [StellarMomentRowV2] = live.holdings.map(\.moment)
        for published in live.created where !rows.contains(where: { $0.nft == published.moment.nft }) { rows.append(published.moment) }
        return rows.compactMap { row -> Coins? in
            guard row.state != "expired" else { return nil }
            var coins = Coins(nft: row.nft, label: row.symbol.isEmpty ? (StellarMomentBoard.title(row) ?? row.nft) : "$\(row.symbol)")
            let sides = live.vesting[row.nft].map { [$0.collector, $0.creator].compactMap { $0 } }
            if row.state == "graduated" {
                guard let vesting = live.vesting[row.nft], vesting.vests, let sides else { return nil }
                for side in sides {
                    let total = BigUInt(side.total) ?? 0, vested = BigUInt(side.vested) ?? 0
                    coins.claimed += BigUInt(side.claimed) ?? 0
                    coins.vesting += total > vested ? total - vested : 0
                }
                coins.claimable = BigUInt(vesting.claimable.total) ?? 0
            } else if let sides {
                coins.pending = sides.reduce(BigUInt(0)) { $0 + (BigUInt($1.total) ?? 0) }
            } else {
                coins.pending = BigUInt(live.holdings.first { $0.moment.nft == row.nft }?.entitlement ?? "0") ?? 0
            }
            return coins.pending > 0 || coins.claimable > 0 || coins.vesting > 0 || coins.claimed > 0 ? coins : nil
        }
    }

    static func totals(_ coins: [Coins]) -> CoinTotals {
        coins.reduce(into: CoinTotals()) { sum, c in
            sum.pending += c.pending
            sum.claimable += c.claimable
            sum.vesting += c.vesting
            sum.claimed += c.claimed
        }
    }

    /// One Claim All's Moments: those with coins to claim, the most first, at most `max` (the contract's limit per
    /// transaction).
    static func batch(_ coins: [Coins], max: Int) -> [Coins] {
        Array(coins.filter { $0.claimable > 0 }.sorted { $0.claimable > $1.claimable }.prefix(Swift.max(1, max)))
    }

    /// A retired Moment's quote asset's code: the API's, else its contract shortened.
    static func code(_ moment: StellarMoment) -> String {
        moment.quoteCode ?? StellarAccountID(moment.quote)?.short ?? moment.quote
    }

    /// A retired edition as Freighter adds it: the v1 Moments contract that minted it and its token id.
    static func freighter(_ edition: StellarMomentsMine.Collected) -> StellarFreighterEdition? {
        StellarAccountID(edition.contract).map {
            StellarFreighterEdition(contract: $0, tokenId: edition.tokenId, name: StellarMomentBoard.title(edition.moment), image: edition.moment.posterUrl ?? edition.moment.mediaUrl,
                                    isVideo: edition.moment.mediaType == "video")
        }
    }
}
#endif
