// Stellar copy of ios/DyorHQ/Moments/MomentsView.swift MomentsView (42cd8c7 sha256:c3651e9c5ddf)
// Stellar copy of ios/DyorHQ/Moments/MomentsView.swift MomentsModel (42cd8c7 sha256:96a11e397acc)
// Stellar copy of ios/DyorHQ/Moments/MomentsUI.swift MomentCard (42cd8c7 sha256:c7a044427784)
// Stellar's Moments tab: the board (docs/DESIGN-stellar-parity.md §8.11.1; docs/DESIGN-stellar-contracts-v2.md §21).
// Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// The Moments board on Stellar, Monad's board on another network: every Moment of contracts v2 as an image-forward
/// card keyed by its NFT address (collecting ones with their progress to graduation), then the retired v1 Moments as
/// legacy editions, with Publish and My Moments. The board is a viewer read (decision 6): it fills with or without a
/// session. A Moment a notification names opens over it.
struct StellarMomentsView: View {
    @Environment(\.stellarSession) private var session
    @Environment(Session.self) private var account
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = StellarMomentsBoardModel()
    /// The time the board is drawn at: it moves on only when a Moment stops collecting or the queued terms lapse
    /// (`face(at:)`); each card's countdown keeps its own (`StellarMomentRowBadge`).
    @State private var clock = Clock()
    @State private var filter: StellarMomentFilter = .all
    @State private var showCreate = false
    @State private var showPortfolio = false
    /// Moments pushed by value (the board, Publish, My Moments) and, from a notification, by address to read first.
    @State private var path = NavigationPath()
    /// A retired v1 Moment a notification names by its number alone: its page brings its own navigation and Close.
    @State private var retiredAlone: StellarRetiredMomentNumber?
    /// The width the board's grid is laid out at: a card's artwork is a column wide, so its next rows are warmed at the
    /// size their cards will ask for (`prefetch(after:)`).
    @State private var gridWidth: CGFloat = 0

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var now: Date { Date(timeIntervalSince1970: TimeInterval(clock.now)) }
    private var shown: [StellarMomentRowV2] { model.moments.filter { filter.shows($0, at: now) } }
    private var shownRetired: [StellarMoment] { model.retired.filter { filter.shows(retired: $0) } }
    private var deployed: Bool { session.map(StellarMomentsBoardModel.isDeployed) ?? false }
    private var canPublish: Bool { deployed && model.publishBlock == nil && model.economics != nil && session?.canSign == true }
    private var reference: StellarMomentsBoardModel.Reader? { session.map { StellarMomentsBoardModel.Reader(session: $0, owner: account.address) } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if session != nil, !deployed {
                    ContentUnavailableView {
                        Label("Moments Not Live Yet", systemImage: "camera.aperture")
                    } description: {
                        Paragraph(LocalizedStringResource("New Moments appear here once the DyorHQ Moments contract is live on Stellar.", table: "StellarMomentsBoard", comment: "The Moments board on Stellar while the network has no DyorHQ Moments contract. DyorHQ and Stellar are never translated"))
                    }
                } else {
                    board
                }
            }
            .navigationTitle(tr("Moments"))
            .navigationDestination(for: StellarMomentListingV2.self) { listing in StellarMomentDetailView(listing: listing) }
            .navigationDestination(for: StellarMomentLink.self) { link in
                switch link {
                case .moment(let nft): StellarMomentDetailView(nft: nft)
                case let .retired(contract, id): StellarMomentDetailView(contract: contract, id: id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); showPortfolio = true } label: { Label("My Moments", systemImage: "person.crop.rectangle.stack") }
                        .disabled(session?.store == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Only on terms read in this session, neither pause set, and an account that can sign.
                    Button { Haptics.tap(); showCreate = true } label: { Label("Publish", systemImage: "plus") }
                        .disabled(!canPublish)
                }
            }
            .sheet(isPresented: $showCreate) {
                StellarCreateMomentView { listing in
                    Task { await reload() }
                    path.append(listing)
                }
            }
            .sheet(isPresented: $showPortfolio) {
                StellarMomentsPortfolioView { opening in
                    showPortfolio = false
                    open(opening)
                }
            }
            .sheet(item: $retiredAlone) { StellarMomentDetailView(id: $0.id) }
            .refreshable { await reload() }
            // Polls only while the board is on screen with the app in front: the task ends when a Moment's page covers it,
            // another tab is chosen or the app goes to the background, and starts again when it is back (`poll`, which
            // then waits out what is left of its 20 s since the last read).
            .task(id: "\(session?.address ?? "")-\(scenePhase == .active)") {
                guard scenePhase == .active, let reference else { return }
                await model.poll(reference)
            }
            .task { await clock.run(showing: { face(at: $0) }) }
            .onChange(of: router.pendingStellar, initial: true) { _, pending in follow(pending) }
            .onAppear {
                // The board saved for the account is in the first frame the tab draws, never "No Moments yet" or a spinner
                // under what it has: read here, before that frame, rather than in the poll's task, which starts after
                // it. Never animated.
                guard let reference else { return }
                withTransaction(\.disablesAnimations, true) { model.showSaved(reference) }
            }
        }
    }

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                // A read that failed says so, with Retry; the Moments last read stay listed.
                if let error = model.error {
                    HStack(alignment: .firstTextBaseline) {
                        InlineError(message: error)
                        Spacer(minLength: 8)
                        Button("Retry") { Task { await reload() } }.font(.footnote.weight(.semibold))
                    }
                }
                Picker("Filter", selection: $filter) {
                    ForEach(StellarMomentFilter.allCases) { $0.label.tag($0) }
                }
                .pickerStyle(.segmented)
                if shown.isEmpty, shownRetired.isEmpty {
                    // Never "No Moments yet" for a feed that couldn't be read, or before a read (or a save) has answered:
                    // until then the board is loading (`firstLoad`).
                    if model.listed, model.error == nil || !model.moments.isEmpty { emptyState }
                } else {
                    if !shown.isEmpty {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(shown) { row in
                                NavigationLink(value: StellarMomentListingV2(row)) { StellarMomentCard(row: row) }
                                    .buttonStyle(.plain)
                                    .onAppear { prefetch(after: row) }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                    }
                    if !shownRetired.isEmpty { retiredSection }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .scrollIndicators(.hidden)
        .overlay { if firstLoad { ProgressView().controlSize(.large) } }
    }

    /// The board has no Moment to show and no read of the feed has answered yet (nor a save been shown), or one is under
    /// way: the spinner, never "No Moments yet" (`BoardFirstRead`).
    private var firstLoad: Bool {
        BoardFirstRead.isLoading(empty: model.moments.isEmpty && model.retired.isEmpty, answered: model.listed, reading: model.loading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("MOMENTS").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                if session?.isTestnet == true { TestnetBadge() }
                Spacer(minLength: 8)
                // The Moments saved when last read, shown while they are read again: said to be, never taken for this read.
                // In the eyebrow's row, so the board doesn't move when the line goes.
                if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }
            }
            Text("Make your favorite moments last forever.").font(.system(.title, design: .serif).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Paragraph(LocalizedStringResource("Publish a photo or video as an NFT on Stellar. Share it with everyone and earn every time it's collected.", table: "StellarMomentsBoard", comment: "Under the Moments board's title on Stellar. NFT and Stellar are never translated"))
                .font(.subheadline).foregroundStyle(.secondary)
            if let block = model.publishBlock {
                // Why Publish is off: the terms couldn't be read, or publishing is paused. The Moments still show.
                Label {
                    Text(verbatim: block.words)
                } icon: {
                    Image(systemName: block == .paused ? "pause.circle" : "exclamationmark.octagon")
                }
                .font(.caption).foregroundStyle(Color.attention)
            } else if model.hasQueuedPolicy(at: now) {
                // A queued policy can't change a Moment silently: a publish binds the terms by value, so one that
                // confirms after they change is refused and the creator reviews the new terms.
                Label("New terms for new Moments are queued. If they take effect before your publish confirms, nothing is published and you review them again.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.attention)
            }
        }
    }

    /// The retired v1 Moments: legacy editions, viewed (and their editions added to Freighter) but never collected or
    /// published again.
    private var retiredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Retired", tableName: "StellarMomentsBoard", comment: "[tight] A heading on the Moments board on Stellar: the Moments of DyorHQ's first, retired Stellar Moments contract")
                .font(.headline)
                .padding(.top, 8)
            Paragraph(LocalizedStringResource("Legacy editions from DyorHQ's first Stellar Moments contract. Collecting is closed; editions stay with their collectors.", table: "StellarMomentsBoard", comment: "Under the Retired heading of the Moments board on Stellar. DyorHQ and Stellar are never translated"))
                .font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(shownRetired) { moment in
                    retiredCard(moment)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    /// A retired Moment's card and the page it opens: pushed by the v1 contract that minted it, or by itself when the
    /// contract isn't known yet.
    @ViewBuilder private func retiredCard(_ moment: StellarMoment) -> some View {
        if let contract = session?.store?.config?.contracts.moments {
            NavigationLink(value: StellarMomentLink.retired(contract: contract, id: moment.id)) { StellarRetiredMomentCard(moment: moment) }
        } else {
            Button { retiredAlone = StellarRetiredMomentNumber(id: moment.id) } label: { StellarRetiredMomentCard(moment: moment) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.aperture").font(.largeTitle).foregroundStyle(Color.brand)
            Text(filter == .all ? "No Moments yet" : "Nothing here yet").font(.headline)
            Text(filter == .all ? "Be the first: publish a photo or video and make it last forever." : "Change the filter to see other Moments.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if filter == .all, canPublish {
                Button("Publish a Moment") { Haptics.tap(); showCreate = true }.buttonStyle(.borderedProminent).foregroundStyle(.white).padding(.top, 4)
            } else if filter != .all {
                Button("Show All Moments") { Haptics.selection(); filter = .all }.padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// What the board shows of the time at `time`: which Moments are collecting, and whether the queued terms lapsed.
    private func face(at time: Int) -> [String] {
        let at = Date(timeIntervalSince1970: TimeInterval(time))
        return model.moments.filter { StellarMomentFilter.isCollecting($0, at: at) }.map(\.nft) + [String(model.hasQueuedPolicy(at: at))]
    }

    /// Warms the artwork of the cards after `row` on the board as it is filtered (`BoardPrefetch`), at a column's width.
    private func prefetch(after row: StellarMomentRowV2) {
        guard gridWidth > 0 else { return }
        let side = (gridWidth - 12) / 2
        for next in BoardPrefetch.following(row.id, in: shown) { StellarMomentArtwork.prefetch(image: next.image, side: side) }
    }

    private func reload() async {
        guard let reference else { return }
        await model.load(reference)
    }

    /// Opens what My Moments chose, over the board.
    private func open(_ opening: StellarMomentOpening) {
        switch opening {
        case .moment(let listing): path.append(listing)
        case let .retired(contract, id):
            if let contract = contract ?? session?.store?.config?.contracts.moments {
                path.append(StellarMomentLink.retired(contract: contract, id: id))
            } else {
                retiredAlone = StellarRetiredMomentNumber(id: id)
            }
        }
    }

    /// A Stellar destination for this tab (a notification, a link): a v2 Moment pushed by its address, a retired one by
    /// its number. The tab is lazy: one asked for before it was first shown is followed as it appears.
    private func follow(_ pending: StellarDestination?) {
        switch pending {
        case .momentV2(let nft):
            router.pendingStellar = nil
            path = NavigationPath([StellarMomentLink.moment(nft: nft)])
        case .moment(let id?):
            router.pendingStellar = nil
            path = NavigationPath()
            retiredAlone = StellarRetiredMomentNumber(id: id)
        default:
            break
        }
    }
}

/// A Moment the board opens by its reference alone: a v2 Moment by its NFT address (its page reads the rest), or a
/// retired v1 Moment by the contract that minted it and its number there.
enum StellarMomentLink: Hashable {
    case moment(nft: String)
    case retired(contract: String, id: Int)
}

/// A retired v1 Moment by its number alone, presented by itself.
struct StellarRetiredMomentNumber: Identifiable, Hashable {
    let id: Int
}

/// The board's filter, as Monad's: every Moment, the ones taking collects now, and the ones whose coin graduated. A Moment
/// that is neither (its window closed, waiting to graduate, expired) shows under All only, and so does a retired v1
/// Moment, which is never collected here and has no coin.
enum StellarMomentFilter: String, CaseIterable, Identifiable {
    case all, collecting, graduated
    var id: String { rawValue }

    /// The segment's name, written out (never the raw value) so it is translated: Monad's own words.
    var label: Text {
        switch self {
        case .all: Text(verbatim: tr(LocalizedStringResource("momentFilter.all", defaultValue: "All")))
        case .collecting: Text("Collecting")
        case .graduated: Text(verbatim: tr(LocalizedStringResource("momentFilter.graduated", defaultValue: "Graduated")))
        }
    }

    /// Whether the v2 Moment `row` belongs under this filter at `now`.
    func shows(_ row: StellarMomentRowV2, at now: Date) -> Bool {
        switch self {
        case .all: true
        case .collecting: Self.isCollecting(row, at: now)
        case .graduated: row.state == "graduated"
        }
    }

    /// Whether the retired v1 Moment `moment` belongs under this filter: under All only.
    func shows(retired moment: StellarMoment) -> Bool {
        self == .all
    }

    /// A v2 Moment takes collects until its deadline, while its state is collecting: the API's own `collecting` filter
    /// and the Moment page's phase (`StellarMomentPhaseV2`). Its window closing, or the collect that completes it, takes
    /// it out of Collecting at that instant. The indexer's `open` only when the deadline can't be read.
    static func isCollecting(_ row: StellarMomentRowV2, at now: Date) -> Bool {
        guard row.state == "collecting" else { return false }
        guard let deadline = StellarFormat.date(row.deadline) else { return row.open }
        return now < deadline
    }
}

/// The board's reads, kept for the time the tab is on screen: the v2 feed, the retired v1 Moments and the Moments terms,
/// each shown as it lands, polled every 20 s and saved for the account (`StellarSaved`, `.momentsBoard`).
@Observable
@MainActor
final class StellarMomentsBoardModel {
    /// What a read needs: the Stellar session and the account the board is saved for.
    struct Reader {
        let session: LiteSession
        /// The account's Monad address, which keys the saved board.
        let owner: Address?
    }

    /// Why Publish is off.
    enum PublishBlock: Equatable {
        case unread, paused

        var words: String {
            switch self {
            case .unread:
                liteTr(LocalizedStringResource("The Moments terms couldn't be read. Publish is off until they are.", table: "StellarMomentsBoard", comment: "Under the Moments board's title on Stellar: the live Moments terms couldn't be read, so Publish is off"))
            case .paused:
                liteTr(LocalizedStringResource("Publishing new Moments is paused.", table: "StellarMomentsBoard", comment: "Under the Moments board's title on Stellar: DyorHQ has paused publishing new Moments"))
            }
        }
    }

    /// The v2 Moments, newest first, without an untitled one (`StellarMomentBoard.visible`).
    private(set) var moments: [StellarMomentRowV2] = []
    /// The retired v1 Moments, newest first.
    private(set) var retired: [StellarMoment] = []
    /// The Moments terms, read live in this session (never saved); nil until read, or where the network has none.
    private(set) var economics: StellarMomentsEconomicsV2?
    /// Why Publish is off, once the terms were asked for.
    private(set) var publishBlock: PublishBlock?
    private(set) var loading = false
    private(set) var error: String?
    /// When the Moments on screen were read, while they are what was saved when last read; nil once a read landed in
    /// this session.
    private(set) var savedAt: Date?
    /// A read of the feed has answered in this session, or the board saved when last read is shown: until then an empty
    /// board is loading (`BoardFirstRead`).
    private(set) var listed = false
    private var savedFor: Address?
    private var restored = false
    /// When the Moments were last read in this session, and for which account (`poll`), on the monotonic clock.
    @ObservationIgnored private var lastRead: ContinuousClock.Instant?
    @ObservationIgnored private var lastReadFor: String?

    /// What the board saves: the Moments as read. Never the terms: Publish stays off until they are read in this
    /// session.
    struct Saved: Codable, Sendable {
        let moments: [StellarMomentRowV2]
        let retired: [StellarMoment]
    }

    /// How often the board reads the Moments again while it is on screen.
    static let pollInterval: TimeInterval = 20
    /// The newest Moments the board shows, at least: the feed's pages are read until it has them, or has no more.
    static let limit = 60

    /// Whether this build pins a Moments v2 contract for the session's network.
    static func isDeployed(_ session: LiteSession) -> Bool {
        !session.env.pinned.contracts("momentsV2").isEmpty
    }

    /// Whether terms are queued for new Moments and haven't lapsed at `now`.
    func hasQueuedPolicy(at now: Date) -> Bool {
        guard let pending = economics?.pendingPolicy else { return false }
        return pending.state(at: now) != "lapsed"
    }

    /// Reads the board every `pollInterval` while the task runs. Back on screen within `pollInterval` of its last read
    /// for this account, it waits out the rest rather than read again at once.
    func poll(_ reader: Reader) async {
        if let lastRead, lastReadFor == reader.session.address {
            let wait = .seconds(Self.pollInterval) - (ContinuousClock.now - lastRead)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        while !Task.isCancelled {
            await load(reader)
            try? await Task.sleep(for: .seconds(Self.pollInterval))
        }
    }

    /// The v2 feed, the retired Moments and the terms, read side by side and each shown as it lands: the list never
    /// waits on the terms, nor the terms on the list. A value read again as it was isn't set again.
    func load(_ reader: Reader) async {
        guard StellarMomentsBoardModel.isDeployed(reader.session), let store = reader.session.store else { return }
        loading = true
        defer { loading = false }
        restoreSaved(reader)
        let epoch = reader.owner.map { StellarSaved.shared.epoch(for: $0) }
        async let termsRead = Self.terms(store)
        async let retiredRead = Self.retired(store)
        async let feedRead = Self.feed(store)
        let (feed, old) = await (feedRead, retiredRead)
        // Every failed read says so, the first or a refresh: the Moments last read stay. A read cut short because the tab
        // went off screen isn't one: the board reads again when it is back.
        if !Task.isCancelled {
            if case .success(let list) = feed, moments != list { moments = list }
            if case .success(let legacy) = old, retired != legacy { retired = legacy }
            if !listed { listed = true }
            let failure = feed.failureText ?? old.failureText
            if error != failure { error = failure }
        }
        // The feed read: the board is this session's now. It is saved once the retired Moments were read too.
        if case .success(let list) = feed, !Task.isCancelled {
            if savedAt != nil { savedAt = nil }
            lastRead = .now
            lastReadFor = reader.session.address
            if case .success(let legacy) = old, let owner = reader.owner, let epoch {
                StellarSaved.shared.save(Saved(moments: list, retired: legacy), .momentsBoard, owner: owner, savedAt: Date(), epoch: epoch)
            }
        }
        let terms = await termsRead
        guard !Task.isCancelled else { return }
        switch terms {
        case .success(let read):
            if economics != read { economics = read }
            let block: PublishBlock? = read.map { $0.publishingPaused || $0.guardianPaused ? .paused : nil } ?? .unread
            if publishBlock != block { publishBlock = block }
        case .failure:
            if publishBlock != .unread { publishBlock = .unread }
        }
    }

    /// Shows the board saved for the account before the board's first frame: a small file on the device, so the tab
    /// opens on the Moments it last showed, said to be saved, rather than on a spinner.
    func showSaved(_ reader: Reader) {
        guard StellarMomentsBoardModel.isDeployed(reader.session) else { return }
        restoreSaved(reader)
    }

    /// The board saved for the account when last read, once per account and only while nothing has been read in this
    /// session. Its media go through the media policy again when drawn (`StellarImages`).
    private func restoreSaved(_ reader: Reader) {
        guard !restored || savedFor != reader.owner else { return }
        restored = true
        savedFor = reader.owner
        guard moments.isEmpty, retired.isEmpty, let owner = reader.owner,
              let saved = StellarSaved.shared.load(Saved.self, .momentsBoard, owner: owner) else { return }
        moments = StellarMomentBoard.visible(saved.value.moments)
        retired = StellarMomentBoard.visible(retired: saved.value.retired)
        listed = true
        savedAt = saved.savedAt
    }

    /// The newest v2 Moments (at least `limit`, page by page), untitled ones left out, or why they couldn't be read. A
    /// viewer read: the feed is the same for everyone.
    private static func feed(_ store: LiteStore) async -> Result<[StellarMomentRowV2], any Error> {
        let moments = MomentsV2Store(store: store)
        do {
            var rows: [StellarMomentRowV2] = []
            var cursor: String?
            repeat {
                let page = try await moments.feed(filter: "all", cursor: cursor)
                rows += page.moments
                cursor = page.nextCursor
            } while rows.count < limit && cursor != nil
            return .success(StellarMomentBoard.visible(rows))
        } catch {
            return .failure(error)
        }
    }

    /// The Moments terms (nil where the network has no v2 Moments), or why they couldn't be read.
    private static func terms(_ store: LiteStore) async -> Result<StellarMomentsEconomicsV2?, any Error> {
        do { return .success(try await MomentsV2Store(store: store).economics()) } catch { return .failure(error) }
    }

    /// The retired v1 Moments; none where the network never had v1 Moments.
    private static func retired(_ store: LiteStore) async -> Result<[StellarMoment], any Error> {
        do {
            return .success(StellarMomentBoard.visible(retired: try await store.moments(filter: "all")))
        } catch let error as LiteAPIError where error.code == "not_deployed" {
            return .success([])
        } catch {
            return .failure(error)
        }
    }
}

private extension Result where Failure == any Error {
    /// The failure in the app's language; nil for a success.
    var failureText: String? {
        guard case .failure(let error) = self else { return nil }
        return LiteErrorText.describe(error)
    }
}

/// How the board words and sorts what it lists.
enum StellarMomentBoard {
    /// A v2 Moment's name on the board: DyorHQ's title, else the NFT's on-chain name; nil when it has neither.
    static func title(_ row: StellarMomentRowV2) -> String? {
        for text in [row.title, row.name] {
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    /// A retired Moment's name: its title; nil without one.
    static func title(_ moment: StellarMoment) -> String? {
        guard let text = moment.title?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The v2 Moments the board lists: never an untitled one.
    static func visible(_ rows: [StellarMomentRowV2]) -> [StellarMomentRowV2] {
        rows.filter { title($0) != nil }
    }

    /// The retired Moments the board lists: never an untitled one.
    static func visible(retired moments: [StellarMoment]) -> [StellarMoment] {
        moments.filter { title($0) != nil }
    }

    /// How far a Moment got to its threshold, in whole percent (0 to 100), for its card.
    static func percent(_ row: StellarMomentRowV2) -> Int {
        Int((min(1, max(0, row.progress)) * 100).rounded(.down))
    }

    /// Whether the card shows its progress to graduation: until it graduates or expires.
    static func showsProgress(_ row: StellarMomentRowV2) -> Bool {
        row.state != "graduated" && row.state != "expired"
    }

    /// A retired Moment's editions: "3" for an open edition, "3/10" for a capped one.
    static func editions(_ moment: StellarMoment) -> String {
        moment.maxEditions > 0 ? "\(moment.minted)/\(moment.maxEditions)" : "\(moment.minted)"
    }
}

/// A board card: square media with the state badge, then the name and ticker, the collect price, the editions and the
/// progress to graduation. Only its badge moves with the time (`StellarMomentRowBadge`).
struct StellarMomentCard: View {
    let row: StellarMomentRowV2

    private var name: String { StellarMomentBoard.title(row) ?? row.nft }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(.tertiarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { StellarMomentArtwork(image: row.image, name: name) }
                    .clipped()
                StellarMomentRowBadge(row: row, onMedia: true).padding(8)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !row.symbol.isEmpty {
                        Text(verbatim: "$\(row.symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Per edition").font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: StellarMomentText.amount(row.price, code: row.quoteCode))
                            .font(.footnote.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Editions").font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: "\(row.minted)").font(.footnote.weight(.semibold)).monospacedDigit()
                    }
                }
                if StellarMomentBoard.showsProgress(row) {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(.tertiarySystemFill)).frame(height: 5)
                                Capsule().fill(Color.brand).frame(width: geo.size.width * min(1, max(0, row.progress)), height: 5)
                            }
                        }
                        .frame(height: 5)
                        Text("\(String(StellarMomentBoard.percent(row)))% to graduation")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A retired v1 Moment's card: its media with the Retired badge, its title, the collect price it had and its editions.
struct StellarRetiredMomentCard: View {
    let moment: StellarMoment

    private var name: String { StellarMomentBoard.title(moment) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(.tertiarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { StellarMomentArtwork(image: moment.posterUrl ?? moment.mediaUrl, name: name) }
                    .clipped()
                Label {
                    Text("Retired", tableName: "StellarMomentsBoard")
                } icon: {
                    Image(systemName: "archivebox")
                }
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.regularMaterial))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(8)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: name).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Per edition").font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: StellarMomentText.amount(moment.price, code: moment.quoteCode ?? StellarAccountID(moment.quote)?.short ?? moment.quote))
                            .font(.footnote.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Editions").font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: StellarMomentBoard.editions(moment)).font(.footnote.weight(.semibold)).monospacedDigit()
                    }
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Where a v2 Moment on the board is, as the indexer recorded it: collecting (with the time left), window closed,
/// graduation pending, graduated or expired. Its page reads the live state (`StellarMomentPhaseBadge`). Colour never
/// stands alone: the word is always there. A collecting Moment's badge keeps its own time, drawn again alone at each
/// instant its countdown reads differently and at the deadline.
struct StellarMomentRowBadge: View {
    let row: StellarMomentRowV2
    var onMedia = false

    var body: some View {
        if StellarMomentFilter.isCollecting(row, at: Date()), let deadline = StellarFormat.date(row.deadline) {
            TimelineView(CountdownSchedule(deadline: Int(deadline.timeIntervalSince1970))) { context in
                label(at: context.date)
            }
        } else {
            label(at: Date())
        }
    }

    private func label(at now: Date) -> some View {
        let phase = StellarMomentRowPhase(row, at: now)
        return Label(words(phase, at: now), systemImage: phase.symbol)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background {
                if onMedia { Capsule().fill(.regularMaterial) } else { Capsule().fill(phase.tint.opacity(0.14)) }
            }
            .foregroundStyle(phase.tint)
            .lineLimit(1)
    }

    private func words(_ phase: StellarMomentRowPhase, at now: Date) -> String {
        switch phase {
        case .collecting:
            let seconds = StellarFormat.date(row.deadline).map { Int($0.timeIntervalSince(now)) } ?? 0
            let left = MomentsFormat.countdown(seconds, short: onMedia)
            return onMedia ? left : tr("Collecting · \(left)")
        case .windowClosed: return tr("Window closed")
        case .graduating: return tr("Graduation pending")
        case .graduated: return tr("Graduated")
        case .expired: return tr("Expired")
        }
    }
}

/// A v2 Moment's place on the board at an instant, from its row: the deadline read in, so a card moves on the moment
/// its window closes.
enum StellarMomentRowPhase: Equatable {
    case collecting, windowClosed, graduating, graduated, expired

    init(_ row: StellarMomentRowV2, at now: Date) {
        switch row.state {
        case "graduated": self = .graduated
        case "expired": self = .expired
        case "graduation_pending": self = .graduating
        default: self = StellarMomentFilter.isCollecting(row, at: now) ? .collecting : .windowClosed
        }
    }

    var tint: Color {
        switch self {
        case .collecting: .brand
        case .windowClosed, .expired: .secondary
        case .graduating: .attention
        case .graduated: .positive
        }
    }

    var symbol: String {
        switch self {
        case .collecting: "clock"
        case .windowClosed: "clock.badge.xmark"
        case .graduating: "hourglass"
        case .graduated: "checkmark.seal.fill"
        case .expired: "xmark.circle"
        }
    }
}
#endif
