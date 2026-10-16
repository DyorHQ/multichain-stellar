// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadView.swift LaunchpadView (42cd8c7 sha256:41bd8d221fed)
// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadView.swift LaunchCard (42cd8c7 sha256:f34f46c31a76)
// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadView.swift LaunchpadModel (42cd8c7 sha256:b8bbc17f3b1c)
// Stellar's Launch tab: the board of launches, with Create and My Launchpad (docs/DESIGN-stellar-parity.md §8.10.1;
// docs/DESIGN-stellar-contracts-v2.md §21). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// The Launch tab on Stellar, laid out as Monad's `LaunchpadView`: an image-forward two-column board of the coins that
/// graduated and the coins still climbing their curve, searched and sorted by the server, with Create (launchpad v2) and
/// My Launchpad. A completed curve waiting to graduate stays in Explore. Coins launched on the retired v1 launchpad are
/// listed apart, under Retired: their pages sell and claim, and nothing new, as on Monad's retired stacks.
///
/// The board is a viewer read (decision 6): it fills with or without a session. What was saved for the account when it
/// was last read in full is in the tab's first frame, said to be, until a read replaces it; a read that fails keeps the
/// coins on screen and says so with Retry.
struct StellarLaunchpadView: View {
    @Environment(\.stellarSession) private var session
    /// The Monad account: what the saved board is kept under (`StellarSaved`).
    @Environment(Session.self) private var account
    @Environment(Router.self) private var router
    @State private var model = StellarLaunchBoardModel()
    @State private var showCreate = false
    @State private var showProfile = false
    @State private var query = ""
    @State private var sort: LaunchSort = .newest
    /// The launch pages over the board.
    @State private var path: [StellarLaunchPage] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var store: LiteStore? { session?.store }

    /// What the board reads: the store, Explore's sort and the search, and the account it saves for.
    private struct Reading: Equatable {
        let store: ObjectIdentifier?
        let request: StellarLaunchBoardModel.Request
        let owner: Address?
    }

    private var request: StellarLaunchBoardModel.Request {
        StellarLaunchBoardModel.Request(sort: Self.serverSort(sort), query: StellarLaunchBoardModel.query(query))
    }

    private var reading: Reading {
        Reading(store: store.map(ObjectIdentifier.init), request: request, owner: account.address)
    }

    /// The server's name for each of Monad's sort chips.
    static func serverSort(_ sort: LaunchSort) -> StellarLaunchMath.Sort {
        switch sort {
        case .newest: .newest
        case .marketCap: .marketCap
        case .progress: .nearGraduation
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            board
            .navigationTitle(tr("Launch"))
            .navigationDestination(for: StellarLaunchPage.self) { page in
                switch page {
                case .launch(let row): StellarLaunchDetailView(token: row.token, launch: row)
                case .token(let token): StellarLaunchDetailView(token: token)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); showProfile = true } label: { Label("My Launchpad", systemImage: "person.crop.circle") }
                        .disabled(store == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.tap(); showCreate = true } label: { Label("New Launch", systemImage: "plus.circle.fill") }
                        .disabled(!canLaunch)
                }
            }
            .searchable(text: $query, prompt: Text("Search coins"))
            .refreshable {
                guard let store else { return }
                await model.load(store: store, request: request, owner: account.address)
            }
            // Restarts with the sort, the search and the account; a search waits for the typing to pause.
            .task(id: reading) {
                guard let store else { return }
                await model.poll(store: store, request: request, owner: account.address)
            }
            // Another account can take over in place without the tabs being rebuilt: the pages over the board were the
            // previous account's, so they go.
            .onChange(of: account.address) { _, _ in path = [] }
            .overlay { if firstLoad { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $showCreate) {
                StellarCreateLaunchView { _ in
                    guard let store else { return }
                    Task { await model.load(store: store, request: request, owner: account.address) }
                }
            }
            .sheet(isPresented: $showProfile) { StellarLaunchpadProfileView() }
            // A coin a notification, My Launchpad or Create named opens over the board, also when the tab is built for it.
            .onChange(of: router.pendingStellar, initial: true) { _, pending in
                guard case .launch(let token?) = pending else { return }
                router.pendingStellar = nil
                open(.token(token))
            }
            .onAppear {
                // The board saved for the account when last read in full is in the first frame the tab draws, never a
                // spinner under what it has: read here, before that frame. Never animated.
                withTransaction(\.disablesAnimations, true) { model.showSaved(owner: account.address) }
            }
        }
    }

    /// A card's page: the coin as read, or, while the board shows what was saved, the coin's token, so its page reads it
    /// now.
    private func page(for coin: StellarLaunch) -> StellarLaunchPage {
        model.savedAt != nil ? .token(coin.token) : .launch(coin)
    }

    /// Pushes `page`, unless the coin's page is already on top.
    private func open(_ page: StellarLaunchPage) {
        if path.last?.token != page.token { path.append(page) }
    }

    private var board: some View {
        let sections = self.sections
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                StellarNetworkLine().font(.footnote).foregroundStyle(.secondary)
                switch model.availability {
                case .notDeployed:
                    Label("New launches open soon.", systemImage: "clock")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .paused:
                    Label {
                        Text("New launches are paused.", tableName: "StellarLaunchBoard", comment: "On Stellar's Launch board: DyorHQ paused new launches on its launchpad for now; coins already launched keep trading")
                    } icon: {
                        Image(systemName: "pause.circle")
                    }
                    .font(.footnote).foregroundStyle(Color.attention).fixedSize(horizontal: false, vertical: true)
                case .unknown, .live:
                    EmptyView()
                }
                // A board that couldn't be read says so, with Retry; the coins already shown stay listed.
                if let error = model.error {
                    HStack(alignment: .firstTextBaseline) {
                        InlineError(message: error)
                        Spacer(minLength: 8)
                        Button("Retry") { reload() }.font(.footnote.weight(.semibold))
                    }
                }
                // The board saved when it was last read, shown while it is read again: said to be, never taken for this read.
                if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }
                if sections.graduated.isEmpty, sections.explore.isEmpty, sections.retired.isEmpty, !firstLoad {
                    // A search that found nothing says so. Only the first load hides this: a poll leaves it on screen. A
                    // board with nothing read shows the error above, never "no coins".
                    if searching { ContentUnavailableView.search(text: query).padding(.top, 40) } else if model.error == nil { emptyState }
                } else {
                    if !sections.graduated.isEmpty {
                        section(title: Text("Graduated"), subtitle: Text("Cleared the graduation threshold"), coins: sections.graduated)
                    }
                    exploreSection(sections.explore)
                    if !sections.retired.isEmpty {
                        section(title: Text(StellarLaunchBoardWords.retired),
                                subtitle: Text("Launched on DyorHQ's retired launchpad. A coin still on its curve can be sold, not bought.", tableName: "StellarLaunchBoard", comment: "Under the Retired section of Stellar's Launch board: these coins come from DyorHQ's previous launchpad; one still on its bonding curve takes sales only. DyorHQ is never translated"),
                                coins: sections.retired)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func section(title: Text, subtitle: Text, coins: [StellarLaunch]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title, count: coins.count, subtitle: subtitle)
            grid(coins)
        }
    }

    private func grid(_ coins: [StellarLaunch]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(coins) { coin in
                NavigationLink(value: page(for: coin)) { StellarLaunchCard(coin: coin) }
                    .buttonStyle(.plain)
                    .onAppear { prefetch(after: coin, in: coins) }
            }
        }
    }

    @ViewBuilder private func exploreSection(_ coins: [StellarLaunch]) -> some View {
        if coins.isEmpty {
            // Nothing on a live curve yet: an invitation, not a gap (not while the launchpad is known to be closed, for a
            // search that found nothing, or for a first load).
            if model.availability != .notDeployed, !searching, !firstLoad {
                exploreEmptyCard
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(Text("Explore"), count: coins.count, subtitle: Text("Coins still climbing toward graduation"))
                sortChips
                grid(coins)
            }
        }
    }

    private var sortChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LaunchSort.allCases) { option in
                    let selected = sort == option
                    Button { if sort != option { Haptics.selection(); sort = option } } label: {
                        Text(verbatim: option.title)
                            .font(.footnote.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(selected ? Color.brand : Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var exploreEmptyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(Text("Explore"), count: nil, subtitle: Text("Coins still climbing toward graduation"))
            VStack(spacing: 12) {
                Image(systemName: "flame").font(.title2).foregroundStyle(Color.brand)
                Paragraph("No coins on the curve yet: launch the first one.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { Haptics.tap(); showCreate = true } label: { Text("Launch a Coin").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).disabled(!canLaunch)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20).padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        }
    }

    /// Warms the artwork of the cards after `coin` in its section, as sorted and searched (`BoardPrefetch`).
    private func prefetch(after coin: StellarLaunch, in coins: [StellarLaunch]) {
        for next in BoardPrefetch.following(coin.id, in: coins) { StellarArtwork.prefetch(image: next.image) }
    }

    /// A section's title with its count (none for an empty section), and what it lists.
    private func sectionHeader(_ title: Text, count: Int?, subtitle: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                title.font(.title3.weight(.semibold))
                if let count {
                    Text(verbatim: "\(count)").font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.brand.opacity(0.14), in: Capsule()).foregroundStyle(Color.brand)
                }
            }
            subtitle.font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "flame").font(.largeTitle).foregroundStyle(Color.brand)
            if model.availability == .notDeployed {
                Text("New Launches Open Soon").font(.headline)
                Paragraph(LocalizedStringResource("Launches appear here once the DyorHQ launchpad is live on Stellar.", table: "StellarLaunchBoard", comment: "Stellar's empty Launch board while DyorHQ's launchpad isn't deployed on this Stellar network yet. DyorHQ and Stellar are never translated"))
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("No Launches Yet").font(.headline)
                Text("Be the first to launch a coin on DyorHQ.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { Haptics.tap(); showCreate = true } label: { Text("Launch a Coin").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!canLaunch)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    /// New Launch is open: a launchpad not known to be missing or paused, and a session that can sign.
    private var canLaunch: Bool {
        (session?.canSign ?? false) && model.availability != .notDeployed && model.availability != .paused
    }

    private var searching: Bool { request.query != nil }

    /// The board has no coin to show and no read has answered yet (nor a save been shown), or one is under way: the spinner
    /// shows over the board, and nothing says "empty" or "not found" (`BoardFirstRead`).
    private var firstLoad: Bool { BoardFirstRead.isLoading(empty: model.isEmpty, answered: model.listed, reading: model.loading) }

    /// What each section lists for the sort and the search on screen.
    private var sections: StellarLaunchBoardModel.Sections {
        StellarLaunchBoardModel.sections(model.lists(for: request))
    }

    private func reload() {
        guard let store else { return }
        Task { await model.load(store: store, request: request, owner: account.address) }
    }
}

/// The words the Launch board and My Launchpad share (table StellarLaunchBoard).
enum StellarLaunchBoardWords {
    static let retired = LocalizedStringResource("Retired", table: "StellarLaunchBoard", comment: "[tight] A section of Stellar's Launch board and of My Launchpad: coins launched on DyorHQ's previous, retired launchpad")
}

/// A page over Stellar's Launch board: a coin's, with its board row, or one opened by its token alone (a notification,
/// My Launchpad, Create, a saved board), which reads the coin first. One typed path holds both, pushed by value.
enum StellarLaunchPage: Hashable {
    case launch(StellarLaunch)
    case token(String)

    /// The coin whose page it is, however it was opened: one page per coin on the stack.
    var token: String {
        switch self {
        case .launch(let row): row.token
        case .token(let token): token
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(token) }
}

/// One coin in Stellar's discovery grid: an image-forward card with its badge, name, market cap and, while it hasn't
/// graduated, its progress toward graduation.
struct StellarLaunchCard: View {
    let coin: StellarLaunch

    private var percent: Int { StellarLaunchMath.progressPercent(coin) }
    private var inRefunds: Bool { coin.phase == "rescued" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // A fixed square sized to the cell width, with the artwork cropped to fill it: every card's height, and its
                // tap area, stays bounded.
                Color(.tertiarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { StellarArtwork(symbol: coin.symbol, image: coin.image) }
                    .clipped()
                badge
                    .padding(8)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: coin.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(verbatim: "$\(coin.symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Market cap").font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: Self.marketCap(coin))
                            .font(.footnote.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        // A retired launchpad's graduated coin is an ordinary pool coin: no caption.
                        if StellarLaunchBoardModel.isRetired(coin), !coin.graduated { Text("Retired launchpad").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        if let created = StellarFormat.date(coin.createdAt) {
                            Text(verbatim: RelativeTime.short(Int(created.timeIntervalSince1970))).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !coin.graduated, !inRefunds {
                    progress
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) // tap area is exactly the card, never its neighbours
    }

    /// The market cap in the coin's quote asset, compact ("41.7K XLM"), or "—" while unread.
    static func marketCap(_ coin: StellarLaunch) -> String {
        guard let cap = coin.marketCapQuote.flatMap(Double.init) else { return "—" }
        let number = NumberStyle.number(cap, compact: true)
        guard let code = coin.quoteCode, !code.isEmpty else { return number }
        return "\(number) \(code)"
    }

    @ViewBuilder private var badge: some View {
        if coin.graduated {
            Label(LaunchPhase.graduated.title, systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(Color.positive)
        } else if inRefunds {
            Text(verbatim: LaunchPhase.refund.title)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.secondary)
        } else if percent >= 80 {
            Text(verbatim: "\(percent)%")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(Color.brand)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill)).frame(height: 5)
                    Capsule().fill(Color.brand).frame(width: geo.size.width * StellarLaunchMath.progress(coin), height: 5)
                }
            }
            .frame(height: 5)
            Text("\(percent)% to graduation").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// What Stellar's Launch board reads and keeps: Explore and Graduated as the server orders them, for the sort and search
/// asked for, the launchpad's terms (open, paused or not deployed), and what was saved for the account when the board
/// was last read in full.
@Observable
@MainActor
final class StellarLaunchBoardModel {
    /// What a read asks the server for: Explore's sort, and a search (nil for none).
    struct Request: Equatable, Sendable {
        let sort: StellarLaunchMath.Sort
        let query: String?
    }

    /// The two sections the server answers, each in its own order.
    struct Lists: Codable, Equatable, Sendable {
        var explore: [StellarLaunch] = []
        var graduated: [StellarLaunch] = []
    }

    /// A search's answer.
    struct Search: Equatable {
        let query: String
        let sort: StellarLaunchMath.Sort
        let lists: Lists
    }

    /// What the board shows: launchpad v2's coins that graduated and those still on their curve (completed curves
    /// included), and the retired v1 launchpad's.
    struct Sections: Equatable {
        let graduated: [StellarLaunch]
        let explore: [StellarLaunch]
        let retired: [StellarLaunch]
    }

    /// Whether launches can be made: the terms not read yet (or unreadable), no v2 launchpad on this network, paused, or
    /// open.
    enum Availability: Equatable { case unknown, notDeployed, paused, live }

    /// What the board saves for an account once read in full (`SavedScreens.Screen.launchBoard`): both sections, and the
    /// sort Explore was read in.
    struct Saved: Codable, Sendable {
        let lists: Lists
        let sort: String
    }

    /// The board without a search, as last read (or saved).
    private(set) var board = Lists()
    /// The sort `board.explore` is in, as the server ordered it; nil until read or restored.
    private(set) var boardSort: StellarLaunchMath.Sort?
    /// The last search's answer.
    private(set) var search: Search?
    /// The launchpad's terms (`/v1/economics`), and the launch plans of the screens over the board.
    private(set) var launches: LaunchV2Store?
    private(set) var loading = false
    private(set) var error: String?
    /// When the board on screen was saved, while it shows what was saved for the account when last read in full; nil once
    /// a read of both sections landed.
    private(set) var savedAt: Date?
    /// A read has answered in this session, or a saved board is shown: until then an empty board is loading
    /// (`BoardFirstRead`), never "No Launches Yet".
    private(set) var listed = false
    /// The account the saved board was looked up for.
    private var restoredFor: Address?

    /// The server's search limit.
    nonisolated static let maxQuery = 64

    /// The search as sent: trimmed, at most 64 characters; nil for none.
    nonisolated static func query(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxQuery))
    }

    var isEmpty: Bool { board.explore.isEmpty && board.graduated.isEmpty && (search?.lists.explore.isEmpty ?? true) && (search?.lists.graduated.isEmpty ?? true) }

    var availability: Availability {
        if let economics = launches?.economics { return economics.launchesEnabled ? .live : .paused }
        return launches?.economicsStatus == .read ? .notDeployed : .unknown
    }

    /// The sections for `request`: the server's own order once its read has landed; until then, the coins on screen
    /// searched and sorted on the phone as the server sorts them.
    func lists(for request: Request) -> Lists {
        Self.lists(board: board, boardSort: boardSort, search: search, request: request)
    }

    nonisolated static func lists(board: Lists, boardSort: StellarLaunchMath.Sort?, search: Search?, request: Request) -> Lists {
        guard let query = request.query else {
            if boardSort == request.sort { return board }
            return Lists(explore: StellarLaunchMath.sorted(board.explore, by: request.sort), graduated: board.graduated)
        }
        if let search, search.query == query {
            if search.sort == request.sort { return search.lists }
            return Lists(explore: StellarLaunchMath.sorted(search.lists.explore, by: request.sort), graduated: search.lists.graduated)
        }
        return Lists(explore: StellarLaunchMath.sorted(matching(board.explore, query), by: request.sort),
                     graduated: matching(board.graduated, query))
    }

    /// The coins whose token is `query`, or whose name or ticker contains it, as the server searches.
    nonisolated static func matching(_ coins: [StellarLaunch], _ query: String) -> [StellarLaunch] {
        coins.filter { $0.token == query || $0.name.localizedCaseInsensitiveContains(query) || $0.symbol.localizedCaseInsensitiveContains(query) }
    }

    /// Launchpad v2's coins in their sections, and the retired launchpad's apart (Explore's first, then the graduated).
    nonisolated static func sections(_ lists: Lists) -> Sections {
        Sections(graduated: lists.graduated.filter { !isRetired($0) }, explore: lists.explore.filter { !isRetired($0) },
                 retired: (lists.explore + lists.graduated).filter(isRetired))
    }

    /// A coin of the retired v1 launchpad: generation 1, or no generation (a server from before v2, which has only v1's).
    nonisolated static func isRetired(_ coin: StellarLaunch) -> Bool { (coin.generation ?? 1) < 2 }

    func poll(store: LiteStore, request: Request, owner: Address?) async {
        // A search waits for the typing to pause: each keystroke restarts this task.
        if request.query != nil {
            try? await Task.sleep(for: .milliseconds(300))
        }
        while !Task.isCancelled {
            await load(store: store, request: request, owner: owner)
            try? await Task.sleep(for: .seconds(20))
        }
    }

    /// Before the tab's first frame, and at the start of every load: a board with nothing on it yet shows what was saved for
    /// `owner` when it was last read in full, said to be.
    func showSaved(owner: Address?) {
        guard let owner, restoredFor != owner else { return }
        restoredFor = owner
        guard board.explore.isEmpty, board.graduated.isEmpty, let saved = StellarSaved.shared.load(Saved.self, .launchBoard, owner: owner) else { return }
        board = saved.value.lists
        boardSort = StellarLaunchMath.Sort(rawValue: saved.value.sort)
        savedAt = saved.savedAt
        listed = true
    }

    /// Reads both sections for `request` and the launchpad's terms. A section that couldn't be read keeps its coins on
    /// screen and the board says so, with Retry. The board without a search is saved for `owner` once both were read.
    func load(store: LiteStore, request: Request, owner: Address?) async {
        loading = true
        defer { loading = false }
        showSaved(owner: owner)
        let launches = self.launches.flatMap { $0.store === store ? $0 : nil } ?? LaunchV2Store(store: store)
        self.launches = launches
        let epoch = owner.map { StellarSaved.shared.epoch(for: $0) }
        async let terms: Void = launches.refreshEconomics()
        async let explore = Self.section(store, "explore", sort: request.sort, query: request.query)
        async let graduated = Self.section(store, "graduated", sort: .newest, query: request.query)
        let (readExplore, readGraduated) = await (explore, graduated)
        _ = await terms
        let readAt = Date()
        // A read cut short because the tab went off screen isn't a failure to show: the board reads again when it's back.
        guard !Task.isCancelled else { return }
        if let query = request.query {
            let previous = search?.query == query ? search?.lists : nil
            let lists = Lists(explore: (try? readExplore.get()) ?? previous?.explore ?? Self.matching(board.explore, query),
                              graduated: (try? readGraduated.get()) ?? previous?.graduated ?? Self.matching(board.graduated, query))
            search = Search(query: query, sort: request.sort, lists: lists)
        } else {
            if let coins = try? readExplore.get() {
                board.explore = coins
                boardSort = request.sort
            }
            if let coins = try? readGraduated.get() { board.graduated = coins }
        }
        let failure = [readExplore, readGraduated].lazy.compactMap { result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }.first
        error = failure.map { LiteErrorText.describe($0) }
        if !listed { listed = true }
        guard failure == nil, request.query == nil else { return }
        savedAt = nil
        if let owner, let epoch {
            StellarSaved.shared.save(Saved(lists: board, sort: request.sort.rawValue), .launchBoard, owner: owner, savedAt: readAt, epoch: epoch)
        }
    }

    /// One section of the board, as the server orders it.
    private static func section(_ store: LiteStore, _ section: String, sort: StellarLaunchMath.Sort, query: String?) async -> Result<[StellarLaunch], Error> {
        do {
            return .success(try await store.launchBoard(section: section, sort: sort.rawValue, query: query).launches)
        } catch {
            return .failure(error)
        }
    }
}
#endif
