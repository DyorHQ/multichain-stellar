import DyorKit
import SwiftUI

/// The Moments board: every Moment as an image-forward card — collecting ones with their progress to graduation,
/// graduated ones with their coin price — plus the flow to publish one and the wallet's own editions and coins.
struct MomentsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MomentsModel()
    /// The time the board is drawn at: it moves on only when a Moment stops collecting or the queued terms lapse
    /// (`MomentBoardTimes`); each card's countdown keeps its own (`MomentStateBadge`).
    @State private var clock = Clock()
    @State private var filter: MomentFilter = .all
    @State private var showCreate = false
    @State private var showPortfolio = false
    /// Moments pushed by value (the board, publish, the portfolio) and, from a link, by (factory, id) to load first.
    @State private var path = NavigationPath()
    /// The width the board's grid is laid out at: a card's artwork is a column wide (`MomentCard`), so its next rows are
    /// warmed at the size their cards will ask for (`prefetch(after:)`).
    @State private var gridWidth: CGFloat = 0

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    enum MomentFilter: String, CaseIterable, Identifiable {
        case all, collecting, graduated
        var id: String { rawValue }
        /// The segment's name, written out (never the raw value) so it is translated.
        var label: Text {
            switch self {
            case .all: return Text(verbatim: tr(LocalizedStringResource("momentFilter.all", defaultValue: "All", comment: "[tight] Moments filter: every Moment")))
            case .collecting: return Text("Collecting", comment: "[tight] Moments filter: Moments still open to collect")
            case .graduated: return Text(verbatim: tr(LocalizedStringResource("momentFilter.graduated", defaultValue: "Graduated", comment: "[tight] Moments filter: the Moments whose coin has graduated")))
            }
        }
    }

    private var shown: [MomentInfo] {
        switch filter {
        case .all: return model.moments
        case .collecting: return model.moments.filter { $0.isCollecting(at: clock.now) }
        case .graduated: return model.moments.filter(\.graduated)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !env.config.moments.isDeployed {
                    // The live (v2) cohort is pending. Past-cohort Moments stay reachable through My Moments and links.
                    ContentUnavailableView {
                        Label("Moments Not Live Yet", systemImage: "camera.aperture")
                    } description: {
                        Paragraph("New Moments appear here once the new DyorHQ Moments contracts are live on Monad. Moments from earlier cohorts are in My Moments.")
                    }
                } else {
                    board
                }
            }
            .navigationTitle(tr("Moments"))
            .navigationDestination(for: MomentInfo.self) { info in MomentDetailView(info: info, onChanged: { Task { await model.load(env: env, account: session.address) } }) }
            .navigationDestination(for: MomentLink.self) { link in MomentLinkView(link: link, onChanged: { Task { await model.load(env: env, account: session.address) } }) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); showPortfolio = true } label: { Label("My Moments", systemImage: "person.crop.rectangle.stack") }
                        .disabled(session.address == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Only on terms the app can bind a publish to (`MomentPolicy.canPublish`): neither pause, the c4 link
                    // base, and an on-chain terms hash that matches the terms read with it.
                    Button { Haptics.tap(); showCreate = true } label: { Label("Publish", systemImage: "plus") }
                        .disabled(!env.config.moments.isDeployed || model.policy?.canPublish != true)
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateMomentView(policy: model.policy) { info in
                    Task { await model.load(env: env, account: session.address) }
                    if let info { path.append(info) }
                }
            }
            .sheet(isPresented: $showPortfolio) { MomentsPortfolioView { info in showPortfolio = false; path.append(info) } }
            // A pull reads what is on chain now: the list the screens share is read again first.
            .refreshable {
                env.invalidateChainReads()
                await model.load(env: env, account: session.address)
            }
            // Polls only while the board is on screen with the app in front: the task ends when a Moment's page covers it,
            // another tab is chosen or the app goes to the background, and starts again when it is back
            // (`MomentsModel.poll`, which then waits out what is left of its 20 s since the last read).
            .task(id: "\(session.address?.hex ?? "")-\(scenePhase == .active)") {
                guard scenePhase == .active else { return }
                await model.poll(env: env, account: session.address)
            }
            .task { await clock.run(showing: { MomentBoardTimes(moments: model.moments, policy: model.policy, at: $0) }) }
            .onChange(of: router.pendingMoment) { _, pending in
                guard let pending else { return }
                path = NavigationPath([pending])
                router.pendingMoment = nil
            }
            .onChange(of: router.pendingMomentLink) { _, link in
                guard let link else { return }
                path = NavigationPath([link])
                router.pendingMomentLink = nil
            }
            .onAppear {
                // The board saved for the wallet is in the first frame the tab draws, never "No Moments yet" or a spinner
                // under what it has (`MomentsModel.showSaved`): read here, before that frame, rather than in the poll's
                // task, which starts after it. Never animated: nothing of the board moves as it comes in.
                withTransaction(\.disablesAnimations, true) { model.showSaved(env: env, account: session.address) }
                // The tab is lazy: a request made before it was first shown is waiting here.
                if let pending = router.pendingMoment {
                    path = NavigationPath([pending])
                    router.pendingMoment = nil
                }
                if let link = router.pendingMomentLink {
                    path = NavigationPath([link])
                    router.pendingMomentLink = nil
                }
            }
        }
    }

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                // A read that failed says so, with Retry; the Moments last read stay listed (as on the Launch board).
                if let error = model.error {
                    HStack(alignment: .firstTextBaseline) {
                        InlineError(message: error)
                        Spacer(minLength: 8)
                        Button("Retry") { Task { await model.load(env: env, account: session.address) } }.font(.footnote.weight(.semibold))
                    }
                }
                Picker("Filter", selection: $filter) {
                    ForEach(MomentFilter.allCases) { $0.label.tag($0) }
                }
                .pickerStyle(.segmented)
                if shown.isEmpty {
                    // Never "No Moments yet" for a feed that couldn't be read, or before a read (or a save) has answered:
                    // until then the board is loading (`firstLoad`).
                    if model.listed, model.error == nil || !model.moments.isEmpty { emptyState }
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(shown) { info in
                            card(info)
                                .buttonStyle(.plain)
                                .onAppear { prefetch(after: info) }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                }
            }
            .padding(16)
            // Nothing here is animated by the saved line. An animation keyed to it (tried in the build 23 speed work)
            // animated whatever changed with it — the Moments a read brought, the tab's first layout — and the first
            // opening after a launch drew the filter over the header, the subtitle's words scattered (`Paragraph` lays
            // Korean out word by word) and the cards' titles twice. The line takes no row of its own (`header`), so
            // nothing moves when it goes.
        }
        .background(Color(.systemGroupedBackground))
        .scrollIndicators(.hidden)
        .overlay { if firstLoad { ProgressView().controlSize(.large) } }
    }

    /// The board has no Moment to show and no read of the feed has answered yet (nor a save been shown), or one is under
    /// way: the spinner, never "No Moments yet" (`BoardFirstRead`) — in the frames before the first read's task starts too.
    private var firstLoad: Bool { BoardFirstRead.isLoading(empty: model.moments.isEmpty, answered: model.listed, reading: model.loading) }

    /// A card and the page it opens: the Moment as read, or, while the board shows what was saved when it was last read
    /// (`MomentsModel.savedAt`), the Moment's link, so its page reads it now (`MomentLinkView`): a Moment's page shows the
    /// Moment it is given as current — its state, its reserve, which actions are open.
    @ViewBuilder private func card(_ info: MomentInfo) -> some View {
        if model.savedAt != nil, let link = MomentLink(key: info.key) {
            NavigationLink(value: link) { MomentCard(info: info) }
        } else {
            NavigationLink(value: info) { MomentCard(info: info) }
        }
    }

    /// Warms the artwork of the cards after `info` on the board as it is filtered (`BoardPrefetch`), at a column's width:
    /// two flexible columns, 12 pt apart (`columns`).
    private func prefetch(after info: MomentInfo) {
        guard gridWidth > 0 else { return }
        let side = (gridWidth - 12) / 2
        for next in BoardPrefetch.following(info.id, in: shown) { MomentArtwork.prefetch(next, side: side) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("MOMENTS", comment: "Eyebrow over the Moments board, in capitals").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // The Moments saved when last read, shown while they are read again: said to be, never taken for this read.
                // In the eyebrow's row, centered on it and no taller than it, so the board doesn't move when the line goes.
                // Never on the eyebrow's baseline: aligned so, the line (a spinner beside its text) hung below the eyebrow
                // and made the row taller.
                if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }
            }
            Text("Make your favorite moments last forever.").font(.system(.title, design: .serif).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Paragraph("Publish a photo or video as an NFT on Monad. Share it with everyone and earn every time it's collected.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let unread = model.policyUnread {
                // The terms couldn't be read: Publish is off (no policy to bind a publish to), the Moments still show.
                Label(unread, systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(Color.attention)
            } else if let policy = model.policy {
                if let block = policy.publishBlock {
                    // Why Publish is off: a pause (governance's or the guardian's), a link base that isn't DyorHQ's, or terms
                    // the app can't bind a publish to.
                    Label(block.message, systemImage: block == .publishingPaused || block == .guardianPaused ? "pause.circle" : "exclamationmark.octagon")
                        .font(.caption).foregroundStyle(Color.attention)
                } else if let pending = policy.pending, !pending.hasLapsed(at: Date(timeIntervalSince1970: TimeInterval(clock.now))) {
                    // MO-4: a queued policy can't change a Moment silently. If it's applied before a publish confirms, the
                    // publish is refused and the creator reviews the new terms; Publish a Moment shows what would change.
                    Label("New terms for new Moments are queued. If they take effect before your publish confirms, nothing is published and you review them again.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.attention)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.aperture").font(.largeTitle).foregroundStyle(Color.brand)
            Text(filter == .all ? "No Moments yet" : "Nothing here yet").font(.headline)
            Text(filter == .all ? "Be the first: publish a photo or video and make it last forever." : "Change the filter to see other Moments.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if filter == .all, session.canSign, model.policy?.canPublish == true {
                Button("Publish a Moment") { Haptics.tap(); showCreate = true }.buttonStyle(.borderedProminent).foregroundStyle(.white).padding(.top, 4)
            } else if filter != .all {
                Button("Show All Moments") { Haptics.selection(); filter = .all }.padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

@Observable
@MainActor
final class MomentsModel {
    private(set) var moments: [MomentInfo] = []
    private(set) var policy: MomentPolicy?
    /// Why Publish is unavailable when the last policy read failed (`MomentsBoard.policyUnread`).
    private(set) var policyUnread: String?
    private(set) var loading = false
    private(set) var error: String?
    /// When the Moments on screen were read, while they are what was saved when last read (`restoreSaved`); nil once a
    /// read landed in this session. The board says it ("Updated 3 min ago").
    private(set) var savedAt: Date?
    /// A read of the feed has answered in this session — its Moments, or why it couldn't be read (`error`) — or the board
    /// saved when it was last read is shown, said to be: until then an empty board is loading (`BoardFirstRead`), never
    /// "No Moments yet".
    private(set) var listed = false
    /// The wallet the saved board was taken for: the board itself is the same for everyone, but each wallet keeps its own
    /// (`SavedScreens`), never another's.
    private var savedFor: Address?
    private var restored = false
    /// When the Moments were last read in this session, and for which wallet (`poll`). On the monotonic clock: a device
    /// clock set back would otherwise make the wait as long as the change, hours of a board not read.
    @ObservationIgnored private var lastRead: ContinuousClock.Instant?
    @ObservationIgnored private var lastReadFor: Address?

    /// What the board saves (`SavedScreens.Screen.momentsBoard`): the Moments as read. Never the policy: Publish stays
    /// off until the terms are read in this session (`MomentPolicy.canPublish`).
    struct Saved: Codable, Sendable {
        let moments: [MomentInfo]
    }

    /// How often the board reads the Moments again while it is on screen.
    static let pollInterval: TimeInterval = 20

    /// Reads the board every `pollInterval` while the task runs (the board on screen, the app in front). Back on screen
    /// within `pollInterval` of its last read for this wallet — from a Moment's page, another tab, the background — it
    /// waits out the rest rather than read again at once: until build 23 every return read the whole board again.
    func poll(env: AppEnvironment, account: Address?) async {
        if let lastRead, lastReadFor == account {
            let wait = .seconds(Self.pollInterval) - (ContinuousClock.now - lastRead)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        while !Task.isCancelled {
            await load(env: env, account: account)
            try? await Task.sleep(for: .seconds(Self.pollInterval))
        }
    }

    /// `account` is the wallet signed in, whose saved board shows at once when nothing has been read in this session.
    /// The Moments and the terms are read side by side and each shown as it lands: the list never waits on the terms (a
    /// policy that can't be read leaves Publish off, with its reason), nor the terms on the list. A value read again as
    /// it was isn't set again, so a poll that found nothing new draws nothing.
    func load(env: AppEnvironment, account: Address?) async {
        guard env.config.moments.isDeployed else { return }
        loading = true
        defer { loading = false }
        // Already shown before the board's first frame (`showSaved`), unless the wallet changed since.
        restoreSaved(env: env, account: account)
        // Saved only while this device's data isn't erased meanwhile (`SavedScreens.epoch`).
        let epoch = env.savedScreens.epoch
        async let termsRead = Self.terms(env: env)
        do {
            let list = try await env.moments.moments(limit: 60)
            let readAt = Date()
            if moments != list { moments = list }
            if !listed { listed = true }
            if error != nil { error = nil }
            if savedAt != nil { savedAt = nil }
            lastRead = .now
            lastReadFor = account
            if !Task.isCancelled { env.savedScreens.save(Saved(moments: list), .momentsBoard, wallet: account, savedAt: readAt, epoch: epoch) }
        } catch {
            // Every failed read says so, the first or a refresh: the Moments last read stay, never a feed frozen unsaid. A
            // read cut short because the tab went off screen isn't one: the feed reloads when it's back.
            if !Task.isCancelled {
                self.error = describe(error)
                if !listed { listed = true }
            }
        }
        let terms = await termsRead
        guard !Task.isCancelled else { return }
        let read = try? terms.get()
        if policy != read { policy = read }
        let unread = MomentsBoard(moments: [], policy: terms).policyUnread
        if policyUnread != unread { policyUnread = unread }
    }

    /// The terms (`MomentsService.policy`), or why they couldn't be read.
    private static func terms(env: AppEnvironment) async -> Result<MomentPolicy?, any Error> {
        do { return .success(try await env.moments.policy()) } catch { return .failure(error) }
    }

    /// Shows the board saved for `account` before the board's first frame (`MomentsView`'s `onAppear`): a small file on the
    /// device, read on the spot (`restoreSaved`), so the tab opens on the Moments it last showed, said to be saved, rather
    /// than on a spinner until its first read's task starts. Nothing while the live cohort is pending.
    func showSaved(env: AppEnvironment, account: Address?) {
        guard env.config.moments.isDeployed else { return }
        restoreSaved(env: env, account: account)
    }

    /// The board saved for `account` when last read (`SavedScreens`), once per wallet and only while nothing has been read
    /// in this session: shown at once, said to be (`savedAt`), until a read replaces it.
    private func restoreSaved(env: AppEnvironment, account: Address?) {
        guard !restored || savedFor != account else { return }
        restored = true
        savedFor = account
        guard moments.isEmpty, let saved = env.savedScreens.load(Saved.self, .momentsBoard, wallet: account) else { return }
        moments = saved.value.moments
        listed = true
        savedAt = saved.savedAt
    }
}
