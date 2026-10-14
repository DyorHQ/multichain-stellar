import BigInt
import Charts
import DyorKit
import PhotosUI
import SwiftUI

/// The launchpad: a discovery board of coins — graduated pools, coins still climbing their bonding curve, and coins in
/// refund mode or migrating — as an image-forward two-column grid, plus the flow to launch a new one. Modeled on the
/// Ponsfamily launchpad, rebuilt in DyorHQ's serif / monochrome system with the Monad-purple accent. The board lists the
/// live launchpad's coins and a retired one's only once graduated (`Launch.listsOnBoard`); a retired launchpad's
/// sell-only coins show only to their holders, under "Your Sell-Only Coins".
struct LaunchpadView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var model = LaunchpadModel()
    @State private var showCreate = false
    @State private var showProfile = false
    @State private var query = ""
    @State private var sort: LaunchSort = .newest
    /// The pages over the board: a launch's, or the loader of one opened by reference.
    @State private var path: [LaunchPage] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            // The retired launchpads' coins list only once graduated (they trade on Swap). One still on its curve is
            // sell-only (owner decision 2026-09-28) and hidden from the board (2026-09-29): its holders reach its page
            // from "Your Sell-Only Coins", Home, the Portfolio and Swap.
            board
            .navigationTitle(tr("Launch"))
            .navigationDestination(for: LaunchPage.self) { page in
                switch page {
                case .launch(let launch): LaunchDetailView(launch: launch)
                case .reference(let reference): LaunchReferenceView(reference: reference)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); showProfile = true } label: { Label("My Launchpad", systemImage: "person.crop.circle") }
                        .disabled(session.address == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.tap(); showCreate = true } label: { Label("New Launch", systemImage: "plus.circle.fill") }
                        .disabled(!env.config.launchpad.isDeployed || !session.canSign)
                }
            }
            .searchable(text: $query, prompt: tr("Search coins"))
            // A pull reads what is on chain now: the list and prices the screens share are read again first.
            .refreshable {
                env.invalidateChainReads()
                await model.load(env: env, account: session.address)
            }
            // Restarts with the wallet: whether it may launch is part of what the create screen is given.
            .task(id: session.address) { await model.poll(env: env, account: session.address) }
            // Another account can take over in place (a Privy session adopted over a watch-only one, say) without the
            // tabs being rebuilt: the pages over the board were the previous account's, so they go.
            .onChange(of: session.address) { _, _ in path = [] }
            .overlay { if firstLoad { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $showCreate) { CreateLaunchView(protocolInfo: model.protocolInfo) { Task { await model.load(env: env, account: session.address) } } }
            .sheet(isPresented: $showProfile) { LaunchpadProfileView() }
            .onChange(of: router.pendingLaunch) { _, launch in
                guard let launch else { return }
                open(.launch(launch))
                router.pendingLaunch = nil
            }
            .onChange(of: router.pendingLaunchReference) { _, reference in
                guard let reference else { return }
                open(.reference(reference))
                router.pendingLaunchReference = nil
            }
            // The tab is built lazily: a page sent before it first appears opens then, over the board.
            .onAppear {
                // The board saved for the wallet is in the first frame the tab draws, never a spinner under what it has
                // (`LaunchpadModel.showSaved`): read here, before that frame, rather than in the poll's task, which starts
                // after it. Never animated: nothing of the board moves as it comes in.
                withTransaction(\.disablesAnimations, true) { model.showSaved(env: env, account: session.address) }
                if let launch = router.pendingLaunch { path = [.launch(launch)]; router.pendingLaunch = nil }
                if let reference = router.pendingLaunchReference { path = [.reference(reference)]; router.pendingLaunchReference = nil }
            }
        }
    }

    /// A card's page: the launch as read, or, while its section shows what was saved when the board was last read
    /// (`saved`: the board's coins while `LaunchpadModel.savedAt` is set, the wallet's sell-only coins while
    /// `heldSellOnlySavedAt` is), the coin's reference, so its page reads it now: a launch page shows the launch it is
    /// given as current — its price, its phase, which trades are open.
    private func page(for launch: Launch, saved: Bool) -> LaunchPage {
        saved ? .reference(LaunchReference(token: launch.token, factory: launch.factory)) : .launch(launch)
    }

    /// The board's coins show what was saved when it was last read (`LaunchpadModel.savedAt`).
    private var boardSaved: Bool { model.savedAt != nil }

    /// The wallet's sell-only coins show what was saved when the board was last read (`LaunchpadModel.heldSellOnlySavedAt`):
    /// the balances behind them may be unread when every launch has been read again.
    private var sellOnlySaved: Bool { model.heldSellOnlySavedAt != nil || model.savedAt != nil }

    /// Pushes `page`, unless its coin's page is already on top: a launch read elsewhere (Home's copy differs in every live
    /// field) or a reference to the same coin is the same page, never a second one over it.
    private func open(_ page: LaunchPage) {
        if path.last?.token != page.token { path.append(page) }
    }

    private var board: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if !env.config.launchpad.isDeployed {
                    Label("New launches open soon.", systemImage: "clock")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // A launchpad whose launches couldn't be read says so, with Retry; its last good coins stay listed.
                if let error = model.error {
                    HStack(alignment: .firstTextBaseline) {
                        InlineError(message: error)
                        Spacer(minLength: 8)
                        Button("Retry") { Task { await model.load(env: env, account: session.address) } }.font(.footnote.weight(.semibold))
                    }
                }
                // The board saved when it was last read, shown while it is read again: said to be, never taken for this read.
                if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }
                if graduated.isEmpty, climbing.isEmpty, refundAndMigrating.isEmpty, sellOnly.isEmpty, !firstLoad {
                    // A search that found nothing says so: a coin the board doesn't list (a retired launchpad's sell-only
                    // coin) is reached from Home, the Portfolio or Swap, not found here. Only the first load hides this:
                    // a poll leaves it on screen. A board with nothing read shows the error above, never "no coins".
                    if searching { ContentUnavailableView.search(text: query).padding(.top, 40) } else if model.error == nil { emptyState }
                } else {
                    if !graduated.isEmpty { section(title: "Graduated", count: graduated.count, subtitle: "Cleared the graduation threshold", coins: graduated, saved: boardSaved) }
                    exploreSection
                    // Every phase has its section (`LaunchPhase.boardSection`), among the coins the board lists: the live
                    // launchpad's in refund mode or migrating.
                    if !refundAndMigrating.isEmpty {
                        section(title: "Refund & Migrating", count: refundAndMigrating.count,
                                subtitle: "In refund mode, holders sell back into the curve; a migrating coin trades once it graduates", coins: refundAndMigrating, saved: boardSaved)
                    }
                    // Only the signed-in wallet's own: the retired launchpads' coins it still holds, which the board
                    // doesn't list, so the Launch tab is never a dead end for their holders. Saved with the board, and
                    // kept when the balances can't be read again (RS-10), it says when it was read once the board's line
                    // has gone.
                    if !sellOnly.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.savedAt == nil, let heldAt = model.heldSellOnlySavedAt { SavedLine(date: heldAt, reading: model.loading) }
                            section(title: "Your Sell-Only Coins", count: sellOnly.count,
                                    subtitle: LaunchBoard.sellOnlySubtitle(sellOnly), coins: sellOnly, saved: sellOnlySaved)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Nothing here is animated by a saved line: an animation keyed to one animates whatever changes with it — the
            // launches a read brought, the tab's first layout, a `Paragraph`'s words — and drew the Moments board garbled
            // on its first opening (build 23 speed work). A line comes and goes with the board it labels.
        }
        .background(Color(.systemGroupedBackground))
    }

    /// A section of `coins`, each opening its page (`page(for:saved:)`): `saved`, they show what was saved when the board
    /// was last read.
    private func section(title: LocalizedStringKey, count: Int, subtitle: LocalizedStringKey, coins: [Launch], saved: Bool) -> some View {
        section(title: title, count: count, subtitle: Text(subtitle), coins: coins, saved: saved)
    }

    /// A section whose subtitle is built at run time (`LaunchBoard.sellOnlySubtitle`), shown as it is.
    @_disfavoredOverload
    private func section<S: StringProtocol>(title: LocalizedStringKey, count: Int, subtitle: S, coins: [Launch], saved: Bool) -> some View {
        section(title: title, count: count, subtitle: Text(verbatim: String(subtitle)), coins: coins, saved: saved)
    }

    private func section(title: LocalizedStringKey, count: Int, subtitle: Text, coins: [Launch], saved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title, count: count, subtitle: subtitle)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(coins) { launch in
                    NavigationLink(value: page(for: launch, saved: saved)) { LaunchCard(launch: launch) }
                        .buttonStyle(.plain)
                        .onAppear { prefetch(after: launch, in: coins) }
                }
            }
        }
    }

    @ViewBuilder private var exploreSection: some View {
        if climbing.isEmpty {
            // Nothing on the live curve yet: an invitation, not a gap (only while the launchpad is live, and not for a
            // search that found nothing, or for a first load).
            if env.config.launchpad.isDeployed, !searching, !firstLoad {
                exploreEmptyCard
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Explore", count: climbing.count, subtitle: "Coins still climbing toward graduation")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LaunchSort.allCases) { option in
                            let selected = sort == option
                            Button { if sort != option { Haptics.selection(); sort = option } } label: {
                                Text(option.title)
                                    .font(.footnote.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(selected ? Color.brand : Color(.secondarySystemGroupedBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    let coins = climbing
                    ForEach(coins) { launch in
                        NavigationLink(value: page(for: launch, saved: boardSaved)) { LaunchCard(launch: launch) }
                            .buttonStyle(.plain)
                            .onAppear { prefetch(after: launch, in: coins) }
                    }
                }
            }
        }
    }

    private var exploreEmptyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Explore", count: nil, subtitle: "Coins still climbing toward graduation")
            VStack(spacing: 12) {
                Image(systemName: "flame").font(.title2).foregroundStyle(Color.brand)
                Paragraph("No coins on the curve yet: launch the first one.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { Haptics.tap(); showCreate = true } label: { Text("Launch a Coin").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).disabled(!session.canSign)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20).padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        }
    }

    /// Warms the artwork of the cards after `launch` in its section, as sorted and searched (`BoardPrefetch`).
    private func prefetch(after launch: Launch, in coins: [Launch]) {
        for next in BoardPrefetch.following(launch.id, in: coins) { LaunchArtwork.prefetch(logo: next.logo) }
    }

    /// A section's title with its count (none for an empty section), and what it lists.
    private func sectionHeader(_ title: LocalizedStringKey, count: Int?, subtitle: LocalizedStringKey) -> some View {
        sectionHeader(title, count: count, subtitle: Text(subtitle))
    }

    private func sectionHeader(_ title: LocalizedStringKey, count: Int?, subtitle: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
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
            Text(env.config.launchpad.isDeployed ? "No Launches Yet" : "New Launches Open Soon").font(.headline)
            Text(env.config.launchpad.isDeployed ? "Be the first to launch a coin on DyorHQ." : "Launches appear here once the new DyorHQ launchpad contracts are live on Monad.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if env.config.launchpad.isDeployed {
                Button { Haptics.tap(); showCreate = true } label: { Text("Launch a Coin").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!session.canSign)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    /// The coins the board lists (`Launch.listsOnBoard`), searched: every public section is taken from these, so a
    /// hidden coin is never listed, counted or found by search.
    private var matching: [Launch] { searched(model.launches.filter(\.listsOnBoard)) }

    /// The wallet's own sell-only coins (`LaunchpadModel.heldSellOnly`), searched too.
    private var sellOnly: [Launch] { searched(model.heldSellOnly) }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The board has no coin to show and no read has answered yet (nor a save been shown), or one is under way: the
    /// spinner shows over the board, and nothing says "empty" or "not found" (`BoardFirstRead`) — in the frames before the
    /// first read's task starts too. Every later poll keeps what is on screen.
    private var firstLoad: Bool { BoardFirstRead.isLoading(empty: model.launches.isEmpty, answered: model.listed, reading: model.loading) }

    private func searched(_ launches: [Launch]) -> [Launch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return launches }
        return launches.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.symbol.localizedCaseInsensitiveContains(q) }
    }

    private var graduated: [Launch] {
        matching.filter { $0.phase.boardSection == .graduated }.sorted { $0.launchedAt > $1.launchedAt }
    }

    private var climbing: [Launch] {
        let live = matching.filter { $0.phase.boardSection == .climbing }
        switch sort {
        case .newest: return live.sorted { $0.launchedAt > $1.launchedAt }
        case .marketCap: return LaunchpadMath.byMarketCap(live, pairUSD: model.pairUSD)
        case .progress: return live.sorted { $0.progressBps > $1.progressBps }
        }
    }

    /// Coins in refund mode (holders sell back into the curve) or migrating (nothing trades until they graduate), newest
    /// first. The board lists none of a retired launchpad's: those are sell-only.
    private var refundAndMigrating: [Launch] {
        matching.filter { $0.phase.boardSection == .refundAndMigrating }.sorted { $0.launchedAt > $1.launchedAt }
    }
}

/// A page over the Launch tab's board: a launch's own, or that of a launch opened by reference
/// (`Router.openLaunch(_: LaunchReference)`), which reads it first. One typed path holds both, pushed by value: a stack
/// bound to a typed path pushes its own element type and nothing else.
enum LaunchPage: Hashable {
    case launch(Launch)
    case reference(LaunchReference)

    /// The coin whose page it is, however it was opened: one page per coin on the stack.
    var token: Address {
        switch self {
        case .launch(let launch): return launch.token
        case .reference(let reference): return reference.token
        }
    }
}

enum LaunchSort: String, CaseIterable, Identifiable {
    case newest, marketCap, progress
    var id: Self { self }
    var title: String {
        switch self {
        case .newest: return tr(LocalizedStringResource("Newest", comment: "Sort chip: the newest coins first [tight]"))
        case .marketCap: return tr(LocalizedStringResource("Market Cap", comment: "Sort chip: the largest market cap first [tight]"))
        case .progress: return tr(LocalizedStringResource("Near Graduation", comment: "Sort chip: the coins closest to graduating first [tight]"))
        }
    }
}

/// One coin in the discovery grid: an image-forward card with its badge, name, market cap and — while on the curve —
/// its progress toward graduation.
struct LaunchCard: View {
    let launch: Launch

    private var isGraduated: Bool { launch.phase == .graduated }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // A fixed square sized to the cell width, with the artwork cropped to fill it. Defining the square
                // with a Color spacer (instead of `.aspectRatio(.fill)` on the image, which reports a size larger than
                // its frame) keeps every card's height — and its tap area — bounded, so a wide or tall image can no
                // longer overflow its cell and spill onto the filter chips above (which was hijacking their taps).
                Color(.tertiarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { LaunchArtwork(symbol: launch.symbol, logo: launch.logo) }
                    .clipped()
                badge
                    .padding(8)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(launch.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(verbatim: "$\(launch.symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Market cap").font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: launch.marketCapInPair.map { "\(NumberStyle.number($0, compact: true)) \(launch.pair.symbol)" } ?? "—")
                            .font(.footnote.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        // A retired launchpad's graduated coin (QT) is an ordinary pool coin: no caption.
                        if launch.isSellOnly { Text("Retired launchpad").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        Text(verbatim: RelativeTime.short(launch.launchedAt)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if launch.phase == .bonding {
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

    @ViewBuilder private var badge: some View {
        if launch.isSellOnly {
            // Only under Your Sell-Only Coins: the public board lists none. A stuck or migrating one is badged with what
            // it waits for: nothing trades until it graduates.
            Text(launch.sellOnlyBadge)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.secondary)
        } else if isGraduated {
            Label("Graduated", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(Color.positive)
        } else if launch.phase.boardSection == .refundAndMigrating {
            Text(launch.phase.title)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.secondary)
        } else if launch.progressBps >= 8000 {
            Text(verbatim: "\(launch.progressBps / 100)%")
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
                    Capsule().fill(Color.brand).frame(width: geo.size.width * min(1, Double(launch.progressBps) / 10_000), height: 5)
                }
            }
            .frame(height: 5)
            Text("\(launch.progressBps / 100)% to graduation").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// A coin's artwork: its uploaded image, or a monogram on a tinted ground when it has none. The logo is whatever string
/// the coin's launcher wrote on-chain, so it is loaded only from DyorHQ's bucket or through the fixed IPFS gateways
/// (`ImageSourcePolicy`), never a host the launcher chose, through the capped loader (RemoteImage).
struct LaunchArtwork: View {
    let symbol: String
    let logo: String
    /// How wide the artwork is drawn, in points: the thumbnail is decoded for this size.
    var pointSize: CGFloat = LaunchArtwork.cardPointSize

    /// The size a board's card draws it at (`LaunchCard`), and what its next rows are warmed at (`prefetch`).
    static let cardPointSize: CGFloat = 240

    /// Warms the picture a board's card for `logo` will ask for — the same sources, size bucket and caps as `body` at
    /// `cardPointSize` — ahead of the board's scroll (`BoardPrefetch`, `ImagePipeline.prefetch`).
    @MainActor static func prefetch(logo: String) {
        let bucket = ImageSizeBucket.bucket(points: cardPointSize)
        RemoteImageLoader.shared.prefetch(ImageSourcePolicy.app.creatorSources(logo).map { RemoteImageSource(url: $0) }, bucket: bucket,
                                          caps: RemoteMedia.caps(forThumbnail: bucket))
    }

    var body: some View {
        Group {
            let sources = ImageSourcePolicy.app.creatorSources(logo).map { RemoteImageSource(url: $0) }
            if !sources.isEmpty {
                RemoteImage(sources: sources, pointSize: pointSize) { loading in
                    if loading { ZStack { Color(.tertiarySystemFill); ImageLoadingSpinner() } } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .accessibilityIgnoresInvertColors()
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.brand.opacity(0.30), Color.brand.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Sized to the frame: a fixed 40 pt shows only "…" in the 34–44 pt rows. Cards and headers keep 40. The letters
            // skip the isolate around right-to-left text (`ChainText.leading`).
            GeometryReader { frame in
                Text(ChainText.leading(symbol, 2).uppercased())
                    .font(.system(size: min(40, frame.size.width * 0.4), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

@Observable
@MainActor
final class LaunchpadModel {
    private(set) var launches: [Launch] = []
    private(set) var protocolInfo: ProtocolInfo?
    /// Each pair asset's USD price, by pair token (MON under the zero address; USDC and AUSD $1), read the way
    /// `LaunchpadProfileModel` reads them: the Market Cap sort compares coins in dollars across pair assets. A pair with
    /// no price is left out, and a failed read keeps the last prices.
    private(set) var pairUSD: [Address: Double] = [:]
    /// The retired launchpads' sell-only coins the signed-in wallet holds, which the board doesn't list: its "Your
    /// Sell-Only Coins" (`LaunchBoard.heldSellOnly`). Cleared on an account change; a read that failed, of a factory
    /// or a balance, keeps it (RS-10: a held coin never drops from the section unsaid).
    private(set) var heldSellOnly: [Launch] = []
    /// When `heldSellOnly` was read, while it is what was saved for the wallet when the board was last read in full
    /// (`restoreSaved`); nil once a read of the wallet's sell-only coins landed in this session. Apart from `savedAt`: the
    /// launches can all be read again while the balances behind this section aren't, and until they are, the section says
    /// when it was read and its coins open by reference, so their pages read them now.
    private(set) var heldSellOnlySavedAt: Date?
    /// The account `heldSellOnly` belongs to.
    private var loadedFor: Address?
    private(set) var loading = false
    private(set) var error: String?
    /// When the board on screen was read, while it shows what was saved for the wallet when last read in full
    /// (`restoreSaved`); nil once a read of every launchpad landed. The board says it ("Updated 3 min ago").
    private(set) var savedAt: Date?
    /// A read of the launchpads has answered in this session — every one, some or none of them (`error` says which) — or
    /// the board saved for the wallet is shown: until then an empty board is loading (`BoardFirstRead`), never "No
    /// Launches Yet".
    private(set) var listed = false

    /// What the board saves for a wallet once read in full (`SavedScreens.Screen.launchBoard`): the launches, each pair
    /// asset's price, and the wallet's sell-only coins.
    struct Saved: Codable, Sendable {
        let launches: [Launch]
        let pairUSD: [Address: Double]
        let heldSellOnly: [Launch]
    }

    func poll(env: AppEnvironment, account: Address?) async {
        while !Task.isCancelled {
            await load(env: env, account: account)
            try? await Task.sleep(for: .seconds(20))
        }
    }

    /// Takes in `account` before the board's first frame (`LaunchpadView`'s `onAppear`) and at the start of every load:
    /// another account's sell-only coins go, and a board with nothing on it yet shows what was saved for this one when it
    /// was last read in full — a small file on the device, read on the spot — said to be (`restoreSaved`). So the tab
    /// opens on the coins it last showed rather than on a spinner until its first read's task starts.
    func showSaved(env: AppEnvironment, account: Address?) {
        // Another account: none of the previous one's coins may stay on screen, even when a read below fails (RS-10).
        if account != loadedFor {
            heldSellOnly = []
            heldSellOnlySavedAt = nil
            loadedFor = account
        }
        // A board with nothing on it yet shows what was saved for this account when last read, said to be (`restoreSaved`).
        restoreSaved(env: env, account: account)
    }

    /// `account` is the signed-in wallet: whether it may launch (`canLaunch`) comes with the factory's terms. A launchpad
    /// whose launches couldn't be read keeps its last good coins on the board, and the board shows the error with Retry
    /// (`LaunchListing.keeping`): never a board with that launchpad's coins silently gone.
    func load(env: AppEnvironment, account: Address?) async {
        // Runs while the live stack is pending too: the retired stacks' launches are still read (and `protocolInfo` is nil).
        loading = true
        defer { loading = false }
        // Already done before the board's first frame (`showSaved`), unless the account changed since.
        showSaved(env: env, account: account)
        // Saved only while this device's data isn't erased meanwhile (`SavedScreens.epoch`).
        let epoch = env.savedScreens.epoch
        async let info = env.launchpad.protocolInfo(extraPairTokens: Token.launchpadPairAssets, account: account)
        let listing = await env.launchpad.launchListing(limit: 60)
        launches = listing.keeping(launches)
        let readAt = Date()
        // Every launchpad read now: nothing saved is left on the board. One that couldn't be read keeps its saved coins,
        // still said to be saved.
        if listing.complete { savedAt = nil }
        // A read cut short because the tab went off screen isn't a failure to show: the board reloads when it's back.
        guard !Task.isCancelled else { return }
        protocolInfo = try? await info
        error = listing.firstError.map(describe)
        if !listed { listed = true }
        let held = await Self.heldSellOnly(env: env, account: account, listing: listing)
        if let held, !Task.isCancelled, account == loadedFor {
            heldSellOnly = held
            heldSellOnlySavedAt = nil
        }
        let prices = await Self.pairPrices(env: env, launches: launches)
        if let prices { pairUSD = prices }
        // Saved for the next opening once every part was read: the launches of every launchpad, the wallet's sell-only
        // coins and the prices.
        if listing.complete, held != nil, prices != nil, !Task.isCancelled, account == loadedFor {
            env.savedScreens.save(Saved(launches: launches, pairUSD: pairUSD, heldSellOnly: heldSellOnly), .launchBoard, wallet: account, savedAt: readAt, epoch: epoch)
        }
    }

    /// The board saved for `account` when last read in full (`SavedScreens`), while the board has nothing on it (nothing read
    /// in this session, or no read answered yet): shown at once, said to be (`savedAt`), until a read of every launchpad
    /// replaces it.
    private func restoreSaved(env: AppEnvironment, account: Address?) {
        guard launches.isEmpty, let saved = env.savedScreens.load(Saved.self, .launchBoard, wallet: account) else { return }
        launches = saved.value.launches
        pairUSD = saved.value.pairUSD
        heldSellOnly = saved.value.heldSellOnly
        heldSellOnlySavedAt = saved.savedAt
        savedAt = saved.savedAt
        listed = true
    }

    /// The sell-only coins among a listing's launches that `account` holds, in one balanceOf multicall; none without an
    /// account or such a coin, and nil when a balance couldn't be read.
    private static func heldSellOnly(env: AppEnvironment, account: Address?, listing: LaunchListing) async -> [Launch]? {
        // A factory that couldn't be read left its coins out of the listing: nothing can be decided from the rest, or a
        // held coin of a retired stack that failed would drop from the section (RS-10).
        guard listing.complete else { return nil }
        let sellOnly = listing.launches.filter { !$0.listsOnBoard }
        guard let account, !sellOnly.isEmpty else { return [] }
        let tokens = sellOnly.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        guard let balances = try? await ERC20.balances(of: tokens, owner: account, rpc: env.rpc, multicall: env.multicall) else { return nil }
        return LaunchBoard.heldSellOnly(sellOnly, balances: balances)
    }

    private static func pairPrices(env: AppEnvironment, launches: [Launch]) async -> [Address: Double]? {
        var tokens: [Address: Token] = [:]
        for launch in launches where tokens[launch.pairToken] == nil {
            tokens[launch.pairToken] = Token(address: launch.pairToken, symbol: launch.pair.symbol, name: launch.pair.symbol, decimals: launch.pair.decimals)
        }
        guard !tokens.isEmpty, let prices = try? await env.prices.prices(for: Array(tokens.values)) else { return nil }
        return prices.compactMapValues { $0.usd > 0 ? $0.usd : nil }
    }
}

/// One coin: price and progress, the curve's trades as candles, and the buy/sell ticket while the curve takes trades —
/// sell only for a coin on a retired launchpad (`Launch.isRetiredLaunchpad`, owner decision 2026-09-28) and in refund
/// mode. A completed curve waiting to graduate (stuck), a migrating launch and a graduated one get the graduation section.
struct LaunchDetailView: View {
    let launch: Launch
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var detail: LaunchDetail?
    /// The latest read of `detail` failed: its rows (stuck since, the Uniswap v4 fallback, hook fees waiting for a sweep,
    /// rewards queued for holders) keep the last good read, and the stats section says so, with Retry.
    @State private var detailUnread = false
    @State private var account: LaunchAccountView?
    @State private var trades: [CurveTrade] = []
    /// The last 24 hours of the curve's trades were all read (`CurveTrades.complete`). False: the read stopped short, and
    /// `trades` are the latest of them; the 24h volume reads as a minimum and the stats section says so, with Retry.
    @State private var tradesComplete = true
    /// The latest read of the trades failed outright: the chart and the list keep the last good read, and the stats
    /// section says so, with Retry.
    @State private var tradesUnread = false
    /// A read of the trades has answered at least once: until then the chart is loading or unread, never "No trades yet",
    /// and the 24h volume reads "—", never 0.
    @State private var tradesRead = false
    @State private var priceSeries: [PricePoint] = []
    @State private var pairUSD: Double?
    /// The coin's holders (`LaunchpadService.holders`): a minimum when not every transfer since the launch was read.
    @State private var holders: HolderCount?
    /// The latest read of the holders failed: the last good count stays, and the stats section says so, with Retry.
    @State private var holdersUnread = false
    @State private var loadingTrades = true
    /// The page's reads asked for after the first — Retry, a trade or a claim done — which key its read (`.task(id:)`):
    /// the read runs as the page's own task, so a new one cancels the one under way rather than stacking another
    /// 80-request scan beside it, and closing the page cancels it. In build 22 and earlier each was a `Task` of its own,
    /// which went on reading after the page closed, one more for every tap; at the logs gate, a screen's scan goes ahead
    /// of the wallet's history (`LogsGate.Lane`).
    @State private var reloads = 0
    @State private var side: TradeSide = .buy
    @State private var amountText = ""
    @State private var buyQuote: BuyQuote?
    @State private var sellQuote: SellQuote?
    @State private var showConfirm = false
    @State private var showClaim = false
    @State private var showCreatorClaim = false
    @State private var showGraduate = false

    init(launch: Launch) {
        self.launch = launch
        // A retired launchpad's curve, and one in refund mode, takes sells only: the ticket never starts on (or offers) Buy.
        _side = State(initialValue: launch.curveBuysOpen ? .buy : .sell)
    }

    private var isCreator: Bool { session.address != nil && session.address == launch.deployer }
    /// Buying on the curve is open: while it trades, and never on a retired launchpad, whose holders can only sell.
    private var buysOpen: Bool { launch.curveBuysOpen }

    /// The coin's price and market cap in USD, from its decimal price (`Launch.pairPrice`), when it and the pair asset's
    /// dollar price are known.
    private var priceUSD: Double? { launch.usdPrice(pairUSD: pairUSD) }
    private var marketCapUSD: Double? { launch.marketCapInPair.flatMap { cap in pairUSD.map { cap * $0 } } }
    /// 24h trading volume in pair units, and in USD when priced.
    private var volume24: Double { trades.filter { Date().timeIntervalSince1970 - Double($0.time) <= 86_400 }.reduce(0) { $0 + Amount.units($1.quoteAmount, decimals: $1.quoteDecimals) } }
    private var volume24USD: Double? { pairUSD.map { volume24 * $0 } }
    /// The 24h volume as the stats show it: "—" until the trades have been read once (never 0 while unread), and a
    /// minimum ("+") while what was read is the latest of them only, or the last good read when the latest failed: either
    /// way every trade it sums is one of the last 24 hours, and only trades it doesn't hold are missing.
    private var volume24Text: String {
        guard tradesRead else { return "—" }
        let value = volume24USD.map { PriceFormat.usdValue($0) } ?? "\(NumberStyle.number(volume24)) \(launch.pair.symbol)"
        return tradesComplete && !tradesUnread ? value : value + "+"
    }
    /// The holder count as the stats show it: "—" until it has been read, a minimum ("+") when not every transfer since the
    /// launch was (`HolderCount.complete`), and "—" for a minimum of none, which says nothing ("0+" read as no holders). A
    /// count kept from the last good read when the latest failed is shown as it was, and the stats section says it
    /// couldn't be read again.
    private var holdersText: String {
        guard let holders else { return "—" }
        if holders.complete { return "\(holders.count)" }
        return holders.count > 0 ? "\(holders.count)+" : "—"
    }

    private enum TradeSide { case buy, sell }
    private var token: Token { Token(address: launch.token, symbol: launch.symbol, name: launch.name, decimals: 18, logoURL: URL(string: launch.logo), isLaunchpad: true) }
    private var pairToken: Token { Token(address: launch.pair.address, symbol: launch.pair.symbol, name: launch.pair.symbol, decimals: launch.pair.decimals) }
    private var rawAmount: BigUInt { Amount.parse(amountText, decimals: side == .buy ? launch.pair.decimals : 18) ?? 0 }

    var body: some View {
        List {
            headerSection
            statsSection
            chartSection
            // The ticket only while the curve takes a sell: a completed curve still waiting to graduate (a stuck launch's
            // record says NotGraduated) refuses them, and gets the graduation section with Retry Graduation instead.
            if launch.curveSellsOpen { ticketSection } else { graduatedSection }
            if let account, account.tokenBalance > 0 || account.pendingRewards > 0 { holdingsSection(account) }
            feesSection
            if !trades.isEmpty { tradesSection }
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(launch.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloads) { await load() }
        .task(id: "\(side)-\(rawAmount)") { await quote() }
        .sheet(isPresented: $showConfirm) { confirmation }
        .sheet(isPresented: $showGraduate) {
            ConfirmationSheet(title: "Retry Graduation", confirmTitle: "Graduate", build: { env.launchpad.graduatePlan(launch: launch) }, onDone: { reloads += 1 },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .graduate, title: tr("\(launch.symbol) graduated"), subtitle: launch.graduationVenue.title, hash: hash, section: "launch"), owner: session.address) }) {
                DetailRow("Venue", launch.graduationVenue.title)
                DetailRow("Who pays", "You (gas only)")
            }
        }
        .sheet(isPresented: $showClaim) {
            ConfirmationSheet(title: "Claim Rewards", confirmTitle: "Claim", build: { await env.launchpad.claimRewardsPlan(launch: launch, view: account) }, onDone: { reloads += 1 },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .claim, title: tr("Claimed \(launch.symbol) rewards"), subtitle: account.map { "\(NumberStyle.units($0.pendingRewards, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)" } ?? tr("holder rewards"), hash: hash, section: "launch"), owner: session.address) }) {
                if let account { DetailRow("Pending rewards", verbatim: "\(NumberStyle.units(account.pendingRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
        }
        .sheet(isPresented: $showCreatorClaim) {
            ConfirmationSheet(title: "Claim Creator Fees", confirmTitle: "Claim Fees", build: { env.launchpad.claimEscrowPlan(launch: launch) }, onDone: { reloads += 1 },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .fees, title: tr("Collected \(launch.symbol) creator fees"), subtitle: account.map { "\(NumberStyle.units($0.escrowBalance, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)" } ?? tr("creator fees"), hash: hash, section: "launch"), owner: session.address) }) {
                if let account { DetailRow("Claimable", verbatim: "\(NumberStyle.units(account.escrowBalance, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
                DetailRow("To", session.address?.short ?? "—")
            }
        }
    }

    /// Creator fees and holder-fee-sharing transparency, mirroring Pons: everyone sees the fee mode, the creator can
    /// claim their escrowed fees here. From v1 the escrow pays each fee straight to the fee recipient, and holds only one
    /// it couldn't send; before v1 it holds every fee until claimed. Fee-sharing coins route creator fees to holders
    /// instead.
    private var feesSection: some View {
        Section {
            LabeledContent("Fee mode", value: launch.holderFeeSharing ? tr("Shared with holders") : tr("To creator"))
            if launch.creatorTaxBps > 0 { LabeledContent("Creator tax", value: NumberStyle.basisPoints(launch.creatorTaxBps)) }
            AddressRow(title: "Fee recipient", address: launch.creatorFeeRecipient.isZero ? launch.deployer : launch.creatorFeeRecipient)
            if isCreator, !launch.holderFeeSharing {
                if let account, account.escrowBalance > 0 {
                    LabeledContent("Your claimable fees") {
                        Text(verbatim: "\(NumberStyle.units(account.escrowBalance, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)")
                            .monospacedDigit().fontWeight(.semibold).foregroundStyle(Color.brand)
                    }
                    Button("Claim Creator Fees", systemImage: "banknote") { Haptics.tap(); showCreatorClaim = true }.disabled(!session.canSign)
                } else if launch.generation.pushesFees {
                    // The escrow sends each fee straight to the fee recipient: it keeps only a payment that couldn't be sent.
                    Paragraph("Nothing to claim — fees are paid straight to the fee recipient.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Paragraph("Nothing to claim yet — fees accrue as people trade your coin.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Creator Fees")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Paragraph(verbatim: WordWrap.sentences(launch.holderFeeSharing
                    ? tr("This coin routes its creator fees to holders — each holder claims their pro-rata share (see Your Holdings, or My Launchpad).")
                    : launch.generation.pushesFees
                    ? tr("The creator earns their share of trading fees plus the creator tax, paid straight to the fee recipient. A payment that can't be sent waits in the fee escrow to be claimed; one claim sweeps those across all your launches paired in this asset.")
                    : tr("The creator earns their share of trading fees plus the creator tax; they accrue in the fee escrow and can be claimed any time. One claim sweeps fees across all your launches paired in this asset."),
                    // A Monday Trade pool has no hook: its 1% fee is harvested to DyorHQ, with no creator tax or share in it.
                    launch.graduationVenue == .monday ? tr("These come from curve trades only: once it graduates on Monday Trade, the pool's 1% fee goes to DyorHQ.") : ""))
                LearnMoreLink(.launchpadFeesAndRewards)
            }
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    // By address: its art once the registry knows the coin, its launch's own logo (held to the same hosts)
                    // until then.
                    TokenLogo(token: Token(address: launch.token, symbol: launch.symbol, name: launch.name, decimals: 18,
                                           logoURL: URL(string: launch.logo), isLaunchpad: true), size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(launch.name).font(.title3.weight(.semibold))
                        Text(verbatim: launch.isSellOnly ? "\(launch.statusTitle) · \(tr("Retired launchpad"))" : launch.statusTitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: launch.pairPrice.map { "\(NumberStyle.number($0)) \(launch.pair.symbol)" } ?? "—")
                            .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                        if let priceUSD { Text(PriceFormat.usdPrice(priceUSD)).font(.footnote).foregroundStyle(.secondary).monospacedDigit().accessibilityLabel(PriceFormat.spoken(priceUSD)) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: launch.marketCapInPair.map { "\(NumberStyle.number($0, compact: true)) \(launch.pair.symbol)" } ?? "—").monospacedDigit().fontWeight(.medium)
                        if let marketCapUSD { Text(PriceFormat.usdValue(marketCapUSD)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        else { Text("Market cap").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if launch.phase == .bonding {
                    Gauge(value: Double(launch.progressBps) / 10_000) {
                        Text("Graduation")
                    } currentValueLabel: {
                        Text(verbatim: "\(launch.progressBps / 100)%")
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    Paragraph("Graduates at \(NumberStyle.units(launch.graduationThreshold, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol) raised. Liquidity then moves to a locked \(launch.graduationVenue.title) pool.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            // Graduation is explained by the gauge while the curve trades, and by the graduation section once it doesn't:
            // the link follows the explanation on screen, so there is one either way.
            if launch.phase == .bonding, launch.curveSellsOpen { LearnMoreLink(.launchpadGraduation) }
        }
    }

    private var chartSection: some View {
        Section {
            PriceChart(points: priceSeries, isLoading: loadingTrades, tint: chartTint)
                .frame(height: 180)
                .padding(.vertical, 4)
                .accessibilityLabel("Price from curve trades")
        } header: {
            Text("Price")
        } footer: {
            // Only while the curve trades: a graduated coin trades in its pool, which its Graduated section explains. And only
            // when the last 24 hours were read in full: a read that stopped short or failed isn't "no trades".
            if trades.isEmpty, !loadingTrades, tradesRead, tradesComplete, !tradesUnread, launch.phase == .bonding {
                Paragraph("No trades yet — the chart moves up as people buy on the curve and down as they sell.").font(.caption)
            }
        }
    }

    private var chartTint: Color {
        guard let first = priceSeries.first?.usd, let last = priceSeries.last?.usd, first != last else { return Color.brand }
        return last >= first ? Color.positive : Color.negative
    }

    private var statsSection: some View {
        Section {
            HStack(spacing: 0) {
                stat("24h Volume", volume24Text)
                Divider().frame(height: 34)
                stat("Holders", holdersText)
                Divider().frame(height: 34)
                stat("Progress", "\(launch.progressBps / 100)%")
            }
            if detailUnread {
                HStack(alignment: .firstTextBaseline) {
                    InlineError(message: "Some details of this launch couldn't be read just now.")
                    Spacer(minLength: 8)
                    Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                }
            }
            // A figure built from a read that stopped short, or kept from the last good read, says so: never a part passed
            // off as the whole. Nothing read yet says just that: there is no part.
            if !loadingTrades, tradesUnread || !tradesComplete {
                HStack(alignment: .firstTextBaseline) {
                    if tradesRead {
                        InlineError(message: "Part of this coin's trades couldn't be read just now, so the chart and 24h volume may be missing some.")
                    } else {
                        InlineError(message: "This coin's trades couldn't be read just now.")
                    }
                    Spacer(minLength: 8)
                    Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                }
            }
            if holdersUnread {
                HStack(alignment: .firstTextBaseline) {
                    InlineError(message: "This coin's holders couldn't be read just now.")
                    Spacer(minLength: 8)
                    Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                }
            } else if let holders, !holders.complete {
                // A coin older than one read reaches back (80 requests: about 17 days of its age on the widest endpoint,
                // hours on the narrow ones) always gets a minimum: no failure, and no Retry that could ever do better.
                Paragraph("Counted from this coin's most recent transfers only, so there may be more holders.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var tradesSection: some View {
        Section("Recent Trades") {
            ForEach(trades.reversed().prefix(25)) { trade in
                LaunchTradeRow(trade: trade, symbol: launch.symbol, pair: launch.pair)
            }
        }
    }

    private var ticketSection: some View {
        Section {
            if buysOpen {
                Picker("Side", selection: $side) {
                    Text("Buy").tag(TradeSide.buy)
                    Text("Sell").tag(TradeSide.sell)
                }
                .pickerStyle(.segmented)
            } else {
                Label(launch.isRetiredLaunchpad ? RetiredLaunchpad.notice : tr("Refund mode: sell back into the curve at its price, with no fees."), systemImage: "arrow.up.right.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            AmountField(title: "0" as String, text: $amountText, token: side == .buy ? pairToken : token) {
                guard let account else { return }
                // A native-MON buy keeps the network fee back (as Swap, Send and Bridge Max do), or the buy cannot pay gas.
                let buyable = launch.pair.isNative ? NetworkFeeReserve.spendable(balance: account.pairBalance, reserve: NetworkFeeReserve.monadFallback) : account.pairBalance
                amountText = side == .buy ? Amount.exact(buyable, decimals: launch.pair.decimals) : Amount.exact(account.tokenBalance, decimals: 18)
            }
            if side == .buy, let q = buyQuote, rawAmount > 0 {
                DetailRow("You receive", verbatim: "\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol)")
                DetailRow("Curve fee", verbatim: "\(NumberStyle.units(q.fee, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                if q.snipe > 0 { DetailRow("Early-buy tax", verbatim: "\(NumberStyle.units(q.snipe, decimals: launch.pair.decimals)) \(launch.pair.symbol)", tint: Color.attention) }
                if q.refund > 0 { DetailRow("Refunded (curve full)", verbatim: "\(NumberStyle.units(q.refund, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
            if side == .sell, let q = sellQuote, rawAmount > 0 {
                DetailRow("You receive", verbatim: "\(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                DetailRow("Curve fee", verbatim: "\(NumberStyle.units(q.fee, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                if q.tax > 0 { DetailRow("Creator tax", verbatim: "\(NumberStyle.units(q.tax, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
            PrimaryButton(title: side == .buy ? "Buy \(launch.symbol)" : "Sell \(launch.symbol)",
                          isDisabled: rawAmount == 0 || !session.canSign || (side == .buy ? buyQuote == nil : sellQuote == nil) || shortfall != nil) { showConfirm = true }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text(buysOpen ? "Trade on the Curve" : "Sell on the Curve")
        } footer: {
            if !session.canSign { Text("Sign in to trade.") }
            else if let shortfall { Paragraph(shortfall).foregroundStyle(Color.attention) }
            else if let account { Paragraph("Balance: \(NumberStyle.units(account.tokenBalance, decimals: 18, compact: true)) \(launch.symbol) · \(NumberStyle.units(account.pairBalance, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
        }
    }

    /// Why the trade can't go ahead on this balance (UI-4): the amount is more than the wallet holds. Nil while the
    /// balance is unknown; the network still refuses what the wallet can't pay.
    private var shortfall: String? {
        guard let account, rawAmount > 0 else { return nil }
        if side == .buy, rawAmount > account.pairBalance {
            return tr("Not enough \(launch.pair.symbol): you have \(NumberStyle.units(account.pairBalance, decimals: launch.pair.decimals)).")
        }
        if side == .sell, rawAmount > account.tokenBalance {
            return tr("Not enough \(launch.symbol): you have \(NumberStyle.units(account.tokenBalance, decimals: 18, compact: true)).")
        }
        return nil
    }

    private var graduatedSection: some View {
        Section {
            // Only a graduated coin has a pool to swap in (a retired launchpad's too, both ways). Stuck or migrating, nothing
            // trades yet: no Swap, and no "you can sell" either.
            if launch.phase == .graduated {
                Button("Swap \(launch.symbol) on \(launch.graduationVenue.title)", systemImage: "arrow.left.arrow.right") {
                    router.openSwap(tokenIn: pairToken.isNative ? Token.mon : pairToken, tokenOut: token)
                }
                // The v4 pool key carries fee 0 (the hook levies the launch's poolFeeBps); a Monday Trade pool uses
                // the graduation executor's fixed 1% tier (MondayGraduationExecutor.FEE).
                LabeledContent("Pool fee", value: NumberStyle.basisPoints(launch.graduationVenue == .monday ? 100 : launch.poolFeeBps))
                if launch.graduationVenue == .uniswapV4, let detail, detail.hookFeesAwaitingSweep > 0 {
                    LabeledContent("Waiting for a sweep") {
                        Text(verbatim: "\(NumberStyle.units(detail.hookFeesAwaitingSweep, decimals: launch.pair.decimals)) \(launch.pair.symbol)").monospacedDigit()
                    }
                }
            }
            if isStuck, let detail {
                LabeledContent("Stuck since", value: Date(timeIntervalSince1970: TimeInterval(detail.stuckSince)).formatted(date: .abbreviated, time: .shortened))
                if launch.keepersTakeGraduateFallback, let opens = detail.v4FallbackOpensAt {
                    LabeledContent("Uniswap v4 fallback", value: detail.isV4FallbackOpen(at: Int(Date().timeIntervalSince1970))
                                   ? tr(LocalizedStringResource("Open", comment: "The Uniswap v4 fallback can be used now: an adjective [tight]"))
                                   : tr("Opens \(Date(timeIntervalSince1970: TimeInterval(opens)).formatted(date: .abbreviated, time: .shortened))"))
                }
                Button("Retry Graduation", systemImage: "arrow.clockwise") { showGraduate = true }.disabled(!session.canSign)
            }
        } header: {
            launch.phase == .graduated ? Text("Graduated") : launch.awaitsGraduation ? Text("Graduation Pending") : Text(verbatim: launch.phase.title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if launch.phase == .graduated {
                    // As MemeHook and MondayFeeVault pay them, and as the docs' FAQ describes (GP-6).
                    Paragraph(launch.graduationVenue == .monday
                         ? "The curve's liquidity is permanently locked in a Monday Trade pool — trades now route through the Swap screen. The pool's 1% swap fee is harvested to a DyorHQ fees wallet; it isn't paid to holders or the creator, and there is no creator tax on the pool."
                         : "The curve's liquidity is permanently locked in a Uniswap v4 pool — trades now route through the Swap screen. Each swap pays the pool fee plus the creator tax to the DyorHQ hook: part of the pool fee goes to DyorHQ, and the rest, with the creator tax, to the creator, or to holders when fee sharing is on. \(v4FeeTiming)")
                } else if isStuck {
                    Paragraph(stuckFooter)
                } else if launch.awaitsGraduation {
                    Paragraph("The curve is full. It graduates next, into a locked \(launch.graduationVenue.title) pool, and then trades on the Swap screen.")
                } else {
                    Paragraph("This launch is between phases. Trading resumes when migration completes.")
                }
                LearnMoreLink(.launchpadGraduation)
            }
        }
    }

    /// When the hook pays what a v4 swap earned: a v2 hook pays the holders' part in the swap itself (released to them a
    /// block later) and keeps only the creator's and DyorHQ's parts for a sweep; an older hook keeps everything.
    private var v4FeeTiming: String {
        launch.generation.hasV2Getters
            ? tr("Holders are paid as trades happen; only the creator's and DyorHQ's parts wait in the hook until they're swept.")
            : tr("Fees wait in the hook until they're swept.")
    }

    /// A completed curve whose migration reverted (the factory records `stuckSince`): the audit's rescue paths apply. Only
    /// while it still waits to graduate: a rescued launch keeps its `stuckSince`, but `graduate` reverts
    /// `WrongGraduationPhase` there.
    private var isStuck: Bool { launch.awaitsGraduation && (detail?.stuckSince ?? 0) > 0 }

    /// The app never offers the Uniswap v4 fallback (`graduateFallback`), on any stack: DyorHQ's keepers send it with the
    /// gas it needs (owner decision 2026-09-28). Only the plain Retry Graduation is offered here.
    private var stuckFooter: String {
        guard launch.keepersTakeGraduateFallback else { return tr("The last graduation attempt failed. Anyone can retry it; you only pay the gas.") }
        let waits = detail?.fallbackRule?.waits ?? false
        return waits
            ? tr("The last graduation attempt failed. Anyone can retry it on Monday Trade; you only pay the gas. DyorHQ's keepers will finish the graduation: they retry it with about 29.9M gas and, if Monday Trade still refuses it, move it to a locked Uniswap v4 pool once it has been stuck for a day (a \(launch.pair.symbol) coin stays on Monday Trade until then).")
            : tr("The last graduation attempt failed. Anyone can retry it on Monday Trade; you only pay the gas. DyorHQ's keepers will finish the graduation: they retry it with about 29.9M gas and, if Monday Trade still refuses it, move it to a locked Uniswap v4 pool.")
    }

    private func holdingsSection(_ account: LaunchAccountView) -> some View {
        Section("Your Holdings") {
            LabeledContent("Balance") { AmountText(amount: account.tokenBalance, token: token, compact: true) }
            if account.pendingRewards > 0 {
                LabeledContent("Pending rewards") { Text(verbatim: "\(NumberStyle.units(account.pendingRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)").monospacedDigit() }
                Button("Claim Rewards", systemImage: "gift") { showClaim = true }.disabled(!session.canSign)
            }
            if let detail, detail.queuedRewards > 0 {
                // Rewards wait one block before they are shared out (audit fix against flash-loan reward sniping).
                LabeledContent("Queued for holders") { Text(verbatim: "\(NumberStyle.units(detail.queuedRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)").monospacedDigit() }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            if !launch.description.isEmpty { Paragraph(launch.description).font(.subheadline) }
            AddressRow(title: "Token", address: launch.token)
            AddressRow(title: "Creator", address: launch.deployer)
            LabeledContent("Creator tax", value: NumberStyle.basisPoints(launch.creatorTaxBps))
            LabeledContent("Holder fee sharing", value: launch.holderFeeSharing
                           ? tr(LocalizedStringResource("On", comment: "A setting that is switched on [tight]"))
                           : tr(LocalizedStringResource("Off", comment: "A setting that is switched off [tight]")))
            LabeledContent("Graduation venue", value: launch.graduationVenue.title)
            ForEach(socialLinks, id: \.0) { label, url in
                Link(destination: url) { Label(label, systemImage: "link") }
            }
        }
    }

    private var socialLinks: [(String, URL)] {
        // not localized: X, Telegram, Discord and Farcaster are the services' own names.
        [(tr("Website"), launch.socials.website), ("X", launch.socials.twitter), ("Telegram", launch.socials.telegram), ("Discord", launch.socials.discord), ("Farcaster", launch.socials.farcaster)]
            // Creator-set strings: only web links, never another app's URL scheme (a wallet's dapp link, say).
            .compactMap { label, value in URL(string: value).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host() != nil ? (label, $0) : nil } }
    }

    @ViewBuilder private var confirmation: some View {
        if let address = session.address {
            if side == .buy, buysOpen, let q = buyQuote {
                ConfirmationSheet(title: "Buy \(launch.symbol)", confirmTitle: "Buy", build: { try await env.launchpad.buyPlan(launch: launch, quoteIn: rawAmount, minTokensOut: q.tokensOut * 99 / 100, recipient: address) }, onDone: { amountText = ""; reloads += 1 }, onCompleted: { hash in
                    // Bought here, so chosen here: never shown as Unverified, as a swap into a token isn't.
                    KnownTokenStore.add(token, owner: session.address)
                    KnownTokenStore.markChosen(launch.token, owner: session.address)
                    Activity.record(ActivityRecord(kind: .buy, title: tr("Bought \(launch.symbol)"), subtitle: tr("\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol) for \(NumberStyle.units(rawAmount, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)"), hash: hash, usd: pairUSD.map { Amount.units(rawAmount, decimals: launch.pair.decimals) * $0 }), owner: session.address)
                    // The fill is in the wallet's history in seconds, not at the next top-up: My Launchpad's profit and loss
                    // and activity wait for it (`WalletHistorySnapshot.fillsCoverage`), and Total Volume counts it.
                    env.history.kick(env: env)
                }, intent: .launchpadBuy(token: launch.token, pay: .init(token: launch.pairToken, amount: rawAmount), usd: pairUSD.map { Amount.units(rawAmount, decimals: launch.pair.decimals) * $0 })) {
                    DetailRow("You pay", verbatim: "\(NumberStyle.units(rawAmount, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                    DetailRow("You receive", verbatim: "\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol)")
                    DetailRow("Minimum", "\(NumberStyle.units(q.tokensOut * 99 / 100, decimals: 18, compact: true)) \(launch.symbol) (1% slippage)")
                }
            } else if side == .sell, let q = sellQuote {
                ConfirmationSheet(title: "Sell \(launch.symbol)", confirmTitle: "Sell", build: { await env.launchpad.sellPlan(launch: launch, tokensIn: rawAmount, minQuoteOut: q.quoteOut * 99 / 100, recipient: address) }, onDone: { amountText = ""; reloads += 1 }, onCompleted: { hash in
                    Activity.record(ActivityRecord(kind: .sell, title: tr("Sold \(launch.symbol)"), subtitle: tr("\(NumberStyle.units(rawAmount, decimals: 18, compact: true)) \(launch.symbol) for \(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)"), hash: hash, usd: pairUSD.map { Amount.units(q.quoteOut, decimals: launch.pair.decimals) * $0 }), owner: session.address)
                    env.history.kick(env: env)
                }, intent: .launchpadSell(token: launch.token, amount: rawAmount, usd: pairUSD.map { Amount.units(q.quoteOut, decimals: launch.pair.decimals) * $0 })) {
                    DetailRow("You sell", verbatim: "\(NumberStyle.units(rawAmount, decimals: 18, compact: true)) \(launch.symbol)")
                    DetailRow("You receive", verbatim: "\(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                    DetailRow("Minimum", "\(NumberStyle.units(q.quoteOut * 99 / 100, decimals: launch.pair.decimals)) \(launch.pair.symbol) (1% slippage)")
                }
            }
        }
    }

    private func load() async {
        async let d = env.launchpad.launch(token: launch.token, factory: launch.factory)
        async let t = env.launchpad.trades(curve: launch.curve, pair: launch.pair)
        async let h = env.launchpad.holders(token: launch.token, excluding: [launch.curve], launchedAt: launch.launchedAt)
        async let pu = pairUSDPrice()
        if let address = session.address { account = try? await env.launchpad.accountView(launch, account: address) }
        // A launch that can't be read keeps the last good detail and says so (`LaunchpadService.launch`); one that isn't
        // recorded reads as nil, as before.
        do {
            detail = try await d
            detailUnread = false
        } catch {
            // A read cut short because the page went off screen (a pushed view) isn't a failure: it reloads on return.
            if !Task.isCancelled { detailUnread = true }
        }
        pairUSD = await pu
        let curveTrades = await t
        // Nor are its empty answers: the chart keeps the trades it has.
        guard !Task.isCancelled else { return }
        if let curveTrades {
            // Read newest first: a read that stopped short holds the latest trades, and says so (`tradesComplete`).
            trades = curveTrades.trades
            tradesComplete = curveTrades.complete
            tradesUnread = false
            tradesRead = true
        } else {
            // A read that failed outright keeps the last good trades, and says so.
            tradesUnread = true
        }
        priceSeries = Self.priceSeries(trades: trades, launch: launch, unit: pairUSD ?? 1)
        loadingTrades = false
        let count = await h
        guard !Task.isCancelled else { return }
        // A count that couldn't be read keeps the last good one, and says so: never 0 for a read that failed.
        if let count { holders = count }
        holdersUnread = count == nil
    }

    private func pairUSDPrice() async -> Double? {
        (try? await env.prices.prices(for: [pairToken]))?[pairToken.address]?.usd
    }

    /// A price line for the chart: one point per curve trade, ending on the live decimal price (`Launch.pairPrice`) when
    /// it was read, with a launch-time baseline prepended so a coin with no trades still draws a flat line rather than an
    /// empty box. Sequential ids keep points distinct even when trades share a block.
    private static func priceSeries(trades: [CurveTrade], launch: Launch, unit: Double) -> [PricePoint] {
        var points: [PricePoint] = []
        var idx: UInt64 = 0
        for trade in trades where trade.price > 0 {
            points.append(PricePoint(block: idx, time: Date(timeIntervalSince1970: TimeInterval(trade.time)), usd: trade.price * unit)); idx += 1
        }
        guard let current = launch.pairPrice.map({ $0 * unit }) else { return points }
        points.append(PricePoint(block: idx, time: Date(), usd: current)); idx += 1
        if points.count < 2 {
            points.insert(PricePoint(block: idx, time: Date(timeIntervalSince1970: TimeInterval(launch.launchedAt)), usd: current), at: 0)
        }
        return points
    }

    private func quote() async {
        // Drop the previous amount's quote first: until this amount's quote lands, Buy/Sell stays disabled, so the
        // minimum-out the sheet signs can never come from a quote for a different amount. `.task(id:)` cancels this
        // task when the amount changes, and a cancelled task's answer is discarded.
        buyQuote = nil
        sellQuote = nil
        guard rawAmount > 0, launch.curveSellsOpen else { return }
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        if side == .buy {
            guard buysOpen else { return }
            let fresh = try? await env.launchpad.quoteBuy(curve: launch.curve, quoteIn: rawAmount, recipient: session.address ?? .zero)
            if !Task.isCancelled { buyQuote = fresh }
        } else {
            let fresh = try? await env.launchpad.quoteSell(curve: launch.curve, tokensIn: rawAmount)
            if !Task.isCancelled { sellQuote = fresh }
        }
    }
}

/// One curve fill in the token page's recent-trades list: buy/sell, the token amount, the pair amount, and when — a
/// tap opens the transaction on Monadscan.
private struct LaunchTradeRow: View {
    let trade: CurveTrade
    let symbol: String
    let pair: PairInfo

    var body: some View {
        Group {
            if let hash = trade.transactionHash {
                Link(destination: Monad.explorerTransaction(hash)) { rowContent }.foregroundStyle(.primary)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: trade.isBuy ? "arrow.down.left" : "arrow.up.right")
                .font(.footnote.weight(.bold))
                .frame(width: 30, height: 30)
                .background((trade.isBuy ? Color.positive : Color.negative).opacity(0.14), in: Circle())
                .foregroundStyle(trade.isBuy ? Color.positive : Color.negative)
            VStack(alignment: .leading, spacing: 1) {
                Text(trade.isBuy ? "Buy \(NumberStyle.units(trade.tokenAmount, decimals: 18, compact: true)) \(symbol)" : "Sell \(NumberStyle.units(trade.tokenAmount, decimals: 18, compact: true)) \(symbol)")
                    .font(.subheadline.weight(.medium))
                Text(trade.trader.short).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: "\(NumberStyle.units(trade.quoteAmount, decimals: pair.decimals, compact: true)) \(pair.symbol)")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Text("\(RelativeTime.short(trade.time)) ago").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Launch a coin: pick its image, name and ticker, describe it, choose the pairing asset and economics, optionally
/// buy first. A live "Your coin" card mirrors the discovery grid as you fill it in — the Ponsfamily create flow in
/// DyorHQ's system.
struct CreateLaunchView: View {
    let protocolInfo: ProtocolInfo?
    let onLaunched: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(SocialSession.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = ""
    @State private var description = ""
    @State private var logo = ""
    @State private var website = ""
    @State private var twitter = ""
    @State private var telegram = ""
    @State private var pair: Address = .zero
    @State private var venue: GraduationVenue = .uniswapV4
    @State private var creatorTaxBps = 0
    @State private var holderFeeSharing = true
    @State private var initialBuyText = ""
    @State private var showAdvanced = false
    @State private var showConfirm = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploadingImage = false
    @State private var imageError: String?

    private var symbolValid: Bool { symbol.count >= 2 && symbol.count <= 10 && symbol.allSatisfy { $0.isLetter || $0.isNumber } }
    /// Why this name or ticker can't be launched (`SymbolSafety.createRefusal`): one that reads as a token DyorHQ lists or a
    /// widely traded one, a ticker that doesn't show as itself, a name with hidden characters or longer than 32. Said under
    /// its field, and Review stays off, so a coin made here never carries a warning.
    private var refusal: SymbolSafety.CreateRefusal? {
        SymbolSafety.createRefusal(name: name.trimmingCharacters(in: .whitespaces), symbol: symbol, maxName: SymbolSafety.maxLaunchNameLength)
    }
    private var valid: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 && symbolValid && refusal == nil }
    /// Why the factory would refuse this launch (v2's unsealed or unexpected modules, template 0 switched off, or a
    /// whitelist this wallet isn't on): Review stays off, so nothing, not even a developer buy's approval, is signed.
    /// The launch plan checks again from a fresh read.
    private var blocker: String? {
        guard let protocolInfo else { return tr("The launchpad's terms couldn't be read. Close this screen and try again.") }
        return protocolInfo.launchBlocker?.message
    }
    private var pairInfo: PairInfo? { protocolInfo?.pairs.first { $0.pair.address == pair }?.pair }
    private var initialBuy: BigUInt { Amount.parse(initialBuyText, decimals: pairInfo?.decimals ?? 18) ?? 0 }
    /// aBIL (and any `pairMondayOnly` pair) can only graduate on Monday Trade; the factory reverts `PairRequiresMonday`
    /// if a v4 venue is submitted for one. The picker is then forced to Monday and disabled.
    private var pairMondayOnly: Bool { protocolInfo?.pairs.first { $0.pair.address == pair }?.mondayOnly ?? false }
    /// The venue actually submitted: forced to Monday for Monday-only pairs regardless of the picker's state.
    private var effectiveVenue: GraduationVenue { pairMondayOnly ? .monday : venue }

    var body: some View {
        NavigationStack {
            Form {
                if let blocker {
                    Section {
                        Label(blocker, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Color.attention)
                    }
                }
                imageSection
                previewSection

                Section("Coin") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, v in if v.count > SymbolSafety.maxLaunchNameLength { name = String(v.prefix(SymbolSafety.maxLaunchNameLength)) } }
                    if let refusal, !refusal.isAboutSymbol { InlineError(message: refusal.message) }
                    // Letters of any script and digits: accented Latin, Chinese, Japanese and Korean pass; the guard says
                    // what doesn't show as itself.
                    TextField("Ticker", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: symbol) { _, v in symbol = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10)) }
                    if let refusal, refusal.isAboutSymbol { InlineError(message: refusal.message) }
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
                }
                Section("Links") {
                    TextField("Website", text: $website).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("X profile", text: $twitter).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Telegram", text: $telegram).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Picker("Paired with", selection: $pair) {
                        ForEach(protocolInfo?.pairs.filter(\.approved) ?? [], id: \.pair.address) { Text($0.pair.symbol).tag($0.pair.address) }
                    }
                    Picker("Graduates on", selection: $venue) {
                        Text(GraduationVenue.uniswapV4.title).tag(GraduationVenue.uniswapV4)
                        Text(GraduationVenue.monday.title).tag(GraduationVenue.monday)
                    }
                    .disabled(pairMondayOnly)
                    .onChange(of: pair) { _, _ in if pairMondayOnly { venue = .monday } }
                } header: {
                    Text("Pairing")
                } footer: {
                    if let info = protocolInfo, let pi = pairInfo {
                        VStack(alignment: .leading, spacing: 4) {
                            if pairMondayOnly {
                                Paragraph("Graduates to a locked \(effectiveVenue.title) pool once the curve raises \(NumberStyle.units(pairGraduation, decimals: pi.decimals, compact: true)) \(pi.symbol). A \(pi.symbol) coin graduates on Monday Trade; if it stays stuck for a day, anyone can move it to a locked Uniswap v4 pool. Launch fee \(NumberStyle.units(info.launchFee, decimals: 18)) MON.")
                            } else {
                                Paragraph("Graduates to a locked \(effectiveVenue.title) pool once the curve raises \(NumberStyle.units(pairGraduation, decimals: pi.decimals, compact: true)) \(pi.symbol). Launch fee \(NumberStyle.units(info.launchFee, decimals: 18)) MON.")
                            }
                            LearnMoreLink(.launchACoin)
                        }
                    }
                }
                Section {
                    AmountField(title: "0" as String, text: $initialBuyText, token: pairInfo.map { Token(address: $0.address, symbol: $0.symbol, name: $0.symbol, decimals: $0.decimals) })
                } header: {
                    Text("Developer Buy (Optional)")
                } footer: {
                    Paragraph("Buy your own coin in the same transaction — snipe-tax exempt.")
                }
                advancedSection
            }
            .navigationTitle(tr("Launch a Coin"))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { Haptics.tap(); showConfirm = true }.fontWeight(.semibold).disabled(!valid || blocker != nil) }
            }
            .sheet(isPresented: $showConfirm) {
                if let address = session.address, let info = protocolInfo {
                    // Use the async plan: it reads the launch fee and the on-chain economics hash the factory
                    // requires (`expectedEconomics`). The sync overload leaves that hash zero → LaunchEconomicsMismatch.
                    // Both are bound to what this screen showed: the fee, and the terms hash read with the terms (IOST-2).
                    ConfirmationSheet(
                        title: "Launch \(symbol)", confirmTitle: "Launch \(symbol)",
                        build: {
                            guard let shown = info.pairs.first(where: { $0.pair.address == pair })?.economicsHash else { throw LaunchpadError.termsChanged }
                            return try await env.launchpad.launchPlan(input, from: address, expectedLaunchFee: info.launchFee, expectedEconomics: shown)
                        },
                        onDone: { dismiss(); onLaunched() },
                        onCompleted: { hash in
                            Activity.record(ActivityRecord(kind: .launch, title: tr("Launched $\(symbol)"), subtitle: name.isEmpty ? symbol : name, hash: hash), owner: session.address)
                            // The new coin's picture and DyorHQ label, without waiting for the next 5-minute read.
                            Task { [coins = env.dyorCoins] in await coins.refresh() }
                            // Launched here, so chosen here: its coin is never shown as Unverified, on Home either (whose
                            // discovery would otherwise store it as merely found in the wallet's history). The coin is the
                            // one the live factory's event names for this wallet, never one a caller supplied.
                            let owner = session.address
                            let launchpad = env.launchpad
                            let multicall = env.multicall
                            let launched = input
                            Task { @MainActor in
                                guard let owner, let result = (try? await launchpad.launchResult(transaction: hash)) ?? nil, result.deployer == owner else { return }
                                let read = (try? await ERC20.metadata(result.token, multicall: multicall)) ?? nil
                                let symbol = read?.symbol ?? launched.symbol
                                KnownTokenStore.add(Token(address: result.token, symbol: symbol, name: read?.name ?? (launched.name.isEmpty ? symbol : launched.name), decimals: 18, isLaunchpad: true), owner: owner)
                                KnownTokenStore.markChosen(result.token, owner: owner)
                            }
                        },
                        onView: { hash in
                            // Route to the coin's in-app page instead of the block explorer (the explorer link lives
                            // in Recent Activity). Resolve the new token from the launch tx, then open its page. The
                            // launch was already recorded when it settled (`onCompleted`).
                            Task {
                                let detail = (try? await env.launchpad.launchResult(transaction: hash)).flatMap { $0 }
                                if let result = detail, let launch = (try? await env.launchpad.launch(token: result.token)) ?? nil {
                                    router.openLaunch(launch.launch)
                                    dismiss()
                                } else {
                                    _ = await UIApplication.shared.open(Monad.explorerTransaction(hash))
                                }
                            }
                        },
                        intent: .alwaysAsks(.launch)
                    ) {
                        DetailRow("Coin", verbatim: "\(name) ($\(symbol))")
                        DetailRow("Paired with", pairInfo?.symbol ?? "MON")
                        DetailRow("Graduation", verbatim: pairInfo.map { "\(NumberStyle.units(pairGraduation, decimals: $0.decimals, compact: true)) \($0.symbol)" } ?? "—")
                        DetailRow("Graduation venue", effectiveVenue.title)
                        DetailRow("Creator tax", NumberStyle.basisPoints(creatorTaxBps))
                        DetailRow("Fee sharing", holderFeeSharing ? "On" : "Off")
                        DetailRow("Launch fee", verbatim: "\(NumberStyle.units(info.launchFee, decimals: 18)) MON")
                        // The parsed amount — what is signed — not the typed text.
                        if initialBuy > 0 { DetailRow("Developer buy", verbatim: "\(NumberStyle.units(initialBuy, decimals: pairInfo?.decimals ?? 18)) \(pairInfo?.symbol ?? "MON")") }
                    }
                }
            }
            .onChange(of: photoItem) { _, item in if let item { Task { await uploadImage(item) } } }
            .onAppear { if pair.isZero, let first = protocolInfo?.pairs.first(where: \.approved) { pair = first.pair.address } }
        }
    }

    private var imageSection: some View {
        Section {
            HStack(spacing: 16) {
                LaunchArtwork(symbol: symbol.isEmpty ? "?" : symbol, logo: logo, pointSize: 72)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(logo.isEmpty ? "Choose Image" : "Change Image", systemImage: "photo")
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(uploadingImage)
                    if uploadingImage {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Uploading…").font(.caption).foregroundStyle(.secondary) }
                    } else if let imageError {
                        Paragraph(imageError).font(.caption).foregroundStyle(Color.attention)
                    } else {
                        Text("Square images look best.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var previewSection: some View {
        if valid {
            Section {
                LaunchPreviewCard(name: name, symbol: symbol, logo: logo, pairSymbol: pairInfo?.symbol ?? "MON")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text("Your Coin")
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                Stepper("Creator tax \(NumberStyle.basisPoints(creatorTaxBps))", value: $creatorTaxBps, in: 0...(protocolInfo?.maxCreatorTaxBps ?? 0), step: 25)
                Toggle("Share fees with holders", isOn: $holderFeeSharing).tint(.brand)
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
            }
        } footer: {
            Paragraph(feeFooter)
        }
    }

    /// Where the creator tax and the creator's share of trading fees come from on the chosen venue: the curve and a
    /// Uniswap v4 pool's hook both pay them (to holders instead with fee sharing); a Monday Trade pool has no hook, and its
    /// 1% fee is harvested to DyorHQ (MondayFeeVault).
    private var feeFooter: String {
        let recipients = tr("You receive it with your share of the trading fees; with fee sharing on, holders receive both instead.")
        return effectiveVenue == .monday
            ? tr("Creator tax is charged on curve trades only. \(recipients) After graduation the Monday Trade pool's 1% fee goes to DyorHQ: there is no creator tax or fee share in the pool.")
            : tr("Creator tax is charged on curve trades and, after graduation, on Uniswap v4 pool swaps. \(recipients)")
    }

    private var pairGraduation: BigUInt {
        protocolInfo?.pairs.first { $0.pair.address == pair }?.graduationThreshold ?? 0
    }

    private func uploadImage(_ item: PhotosPickerItem) async {
        uploadingImage = true; imageError = nil
        defer { uploadingImage = false; photoItem = nil }
        do {
            // Uploading needs a DyorHQ Social session (same wallet); connect on demand.
            if !social.isSignedIn { await social.signIn(session: session) }
            guard social.isSignedIn else { imageError = tr("Connect DyorHQ Social to upload an image."); return }
            // The middle square, 512 pixels a side (`LaunchImage`): what the preview shows is what every screen shows.
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.launchJPEG() else {
                imageError = tr("That image could not be read.")
                return
            }
            logo = try await social.uploadLaunchImage(jpeg: jpeg).absoluteString
            Haptics.success()
        } catch {
            imageError = describe(error)
        }
    }

    private var input: LaunchInput {
        LaunchInput(name: name.trimmingCharacters(in: .whitespaces), symbol: symbol, description: description, logo: logo, socials: Socials(twitter: twitter, telegram: telegram, discord: "", website: website, farcaster: ""), creatorTaxBps: creatorTaxBps, holderFeeSharing: holderFeeSharing, graduationVenue: effectiveVenue, pairToken: pair, initialBuy: initialBuy)
    }
}

/// The live preview shown while creating a coin — the same shape as a discovery-grid card.
private struct LaunchPreviewCard: View {
    let name: String
    let symbol: String
    let logo: String
    let pairSymbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LaunchArtwork(symbol: symbol.isEmpty ? "?" : symbol, logo: logo)
                .aspectRatio(1, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    (name.isEmpty ? Text("Your coin") : Text(verbatim: name)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    // not localized: a ticker stands in for the one still to be typed, as tickers are never translated.
                    Text(verbatim: "$\(symbol.isEmpty ? "TICKER" : symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Text("New", comment: "A badge on a new coin: just launched, or too new to have a 24h change [tight]").font(.caption2.weight(.semibold)).foregroundStyle(Color.brand)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Color.brand.opacity(0.14), in: Capsule())
                    Spacer()
                    Text("Pairs with \(pairSymbol)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
