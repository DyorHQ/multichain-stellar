import BigInt
import Charts
import DyorKit
import SwiftUI

/// Portfolio first, then the market. The layout follows a trading app's home: a balance hero with the spot,
/// perps and launchpad split, quick actions, an allocation ring, top movers, and the wallet's own holdings.
/// Everything reads straight from Monad and Perpl each refresh; the design stays in DyorHQ's system (SF type,
/// serif display, semantic green/red), and works on paper and ink grounds alike.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(SocialSession.self) private var social
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = HomeModel()
    /// The Add funds card for an empty passkey account (MERA-PLAN §4).
    @State private var funding = FundingWatch()
    @State private var tokenTab: HomeTokenTab = .popular
    @State private var holdingTab: HoldingCategory = .spot
    @State private var showReceive = false
    @State private var showBridge = false
    @State private var showSend = false
    @State private var showTransfer = false
    @State private var showSearch = false
    @State private var searchTarget: MarketRow?
    /// The Top Tokens rank column: 16 pt at the default text size, grown with the rank's footnote text so a digit never
    /// shows as "…" at the accessibility sizes. The dividers are inset by it too (`TokenListRow.textInset`).
    @ScaledMetric(relativeTo: .footnote) private var rankWidth: CGFloat = 16

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if session.isPasskeyAccount {
                        HStack { SessionPill(); Spacer() }
                    }
                    if session.isPasskeyAccount, funding.phase.isVisible, let address = session.address {
                        AddFundsCard(phase: funding.phase, address: address,
                                     onBridge: { showBridge = true },
                                     onShowQR: { showReceive = true },
                                     onTrade: { trade in router.openSwap(tokenIn: trade.pay, tokenOut: trade.receive) },
                                     onClose: { funding.close() })
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                    heroCard
                    quickActions
                    if let split = model.split, split.total > 0 || !model.holdings.isEmpty { allocationCard(split) }
                    topTokensCard
                    holdingsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.snappy, value: funding.phase)
                // Nothing here is animated by a saved line: an animation keyed to one animates whatever changes with it —
                // the figures a read brought, the screen's first layout, a `Paragraph`'s words — and drew the Moments board
                // garbled on its first opening (build 23 speed work). Home's own line sits under the balance, beside Total
                // Volume's column, so the card keeps its height when it goes while that column is the taller (`savedLine`).
            }
            .background(Color(.systemGroupedBackground))
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { HomeHeader(showSearch: $showSearch, error: model.error ?? volumeError, updatedAt: model.updatedAt) }
            .navigationDestination(for: MarketRow.self) { row in TokenDetailView(row: row) }
            .navigationDestination(item: $searchTarget) { row in TokenDetailView(row: row) }
            // A pull awaits Home's own reads, side by side, never a round of the history: that reads on behind the screen
            // (`HistoryModel.kick`), and Total Volume follows it (`env.history.version`).
            // The reads run in a task of their own: SwiftUI cancels a pull's action when the list redraws under it (the
            // loads' own `loading` changes do), and a cancelled load publishes nothing, so a pull used to end with Home
            // unchanged. The spinner still waits for both. The reads the screens share are read again first
            // (`invalidateChainReads`): a pull asks for what is on chain now.
            .refreshable {
                env.invalidateChainReads()
                env.history.kick(env: env)
                await Task {
                    async let home: () = model.load(env: env, address: session.address)
                    async let portfolio: () = env.portfolio.load(env: env, address: session.address, perplKey: perplTrading.key, force: true, passkey: session.isPasskeyAccount)
                    _ = await (home, portfolio)
                }.value
            }
            // What was saved for the wallet — Home's parts and the Portfolio's Total Volume — is in Home's first frame,
            // never placeholders under figures the phone has (`HomeModel.showSaved`, `PortfolioModel.showSaved`): small
            // files on the device, read here, before that frame, rather than in the loads' tasks, which start after it.
            // Never animated: nothing moves as they come in.
            .onAppear {
                withTransaction(\.disablesAnimations, true) {
                    model.showSaved(env: env, address: session.address)
                    env.portfolio.showSaved(env: env, address: session.address)
                }
            }
            .task(id: session.address) { await model.poll(env: env, address: session.address) }
            .task(id: session.address) { await env.portfolio.load(env: env, address: session.address, perplKey: perplTrading.key, force: false, passkey: session.isPasskeyAccount) }
            // The history fills in behind the screen (`HistoryModel`): Total Volume follows it, and the tokens it shows
            // the wallet received join the holdings.
            .task(id: env.history.version) {
                env.portfolio.applyHistory(env.history.snapshot, version: env.history.version, for: session.address)
                await model.discoverHeldTokens(env: env, address: session.address)
            }
            // A Perpl key that appears (a passkey session unlocked) loads the perps history the last load lacked.
            .task(id: perplTrading.key != nil) {
                if perplTrading.key != nil { await env.portfolio.load(env: env, address: session.address, perplKey: perplTrading.key, force: false, passkey: session.isPasskeyAccount) }
            }
            // The Add funds card's balance watch: a passkey account only, while Home is on screen and the app is active.
            .task(id: "\(session.isPasskeyAccount ? session.address?.hex ?? "" : "")-\(scenePhase == .active)") {
                guard session.isPasskeyAccount, scenePhase == .active, let address = session.address else { return }
                await funding.watch(env: env, address: address, home: model)
            }
            .onChange(of: funding.phase.isArrival) { _, arrived in
                // Show the deposit in the balance straight away rather than at Home's next 30 s refresh.
                if arrived { Task { await model.load(env: env, address: session.address) } }
            }
            .sensoryFeedback(.success, trigger: funding.phase.isArrival) { _, arrived in arrived }
            .overlay { if model.rows.isEmpty, model.loading { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $showReceive) { if let address = session.address { ReceiveSheet(address: address) } }
            .sheet(isPresented: $showBridge) { BridgeView(env: env) }
            .sheet(isPresented: $showSend) { SendSheet() }
            .sheet(isPresented: $showTransfer) { TransferSheet() }
            .sheet(isPresented: $showSearch) {
                // Balances only once read in this session: never saved ones beside the search.
                TokenPickerSheet(selected: .mon, balances: model.reads.isSaved(.spot) ? [:] : Dictionary(uniqueKeysWithValues: model.rows.map { ($0.token.address, $0.balance) }), universe: KnownTokenStore.universe(owner: session.address), tradableOnly: false,
                                 unverified: KnownTokenStore.unverified(owner: session.address)) { token in
                    // Open the token's page; a token outside the priced list gets a bare row (price loads on the page).
                    searchTarget = model.rows.first { $0.token.address == token.address }.map(pageRow) ?? MarketRow(token: token, usd: nil, change24h: nil, balance: 0)
                }
            }
        }
    }

    // MARK: Hero

    /// The balance hero, in the reference layout: the total on the left with its 24h move; on the right the
    /// wallet's Total Volume across DyorHQ for the selected period, with the period switch right under it.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                // The total and the day's move in it wait for every part of the wallet (`HomeModel.totalValue`).
                let unread = model.totalValue == nil
                VStack(alignment: .leading, spacing: 4) {
                    Text(PriceFormat.usdValue(model.totalValue ?? 0))
                        .font(.system(size: 40, weight: .semibold, design: .serif))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText(value: model.totalValue ?? 0))
                        .unreadFigure(unread)
                    HStack(spacing: 8) {
                        Text(PriceFormat.usdValue(changeAmount, signed: true))
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                            .foregroundStyle(unread ? Color.secondary : changeAmount < 0 ? Color.negative : Color.positive)
                        ChangeBadge(value: unread ? 0 : model.change24h ?? 0)
                    }
                    .unreadFigure(unread)
                    if let savedAt = model.savedAt { savedLine(savedAt) }
                }
                Spacer(minLength: 8)
                totalVolume
            }

            Divider()

            HStack(alignment: .top) {
                statColumn("Avail. Balance", value: model.availableBalance, tint: .primary)
                Spacer()
                statColumn("In Use", value: model.inUse, tint: (model.inUse ?? 0) > 0 ? .positive : .primary, alignment: .trailing)
            }

            Divider()

            HStack(spacing: 10) {
                splitStat(.spot, model.spotValue, .allocationSpot)
                splitStat(.perps, model.perpsValue, .allocationPerps)
                splitStat(.launchpad, model.launchpadValue, .allocationLaunchpad)
                splitStat(.moments, model.momentsValue, .allocationMoments)
            }
        }
        .padding(16)
        .cardBackground()
    }

    /// Today's move in dollars, from the value-weighted 24h change.
    private var changeAmount: Double {
        guard let total = model.totalValue, let change = model.change24h, change != 0 else { return 0 }
        return total - total / (1 + change / 100)
    }

    /// The wallet's chain history couldn't be read to the head, or the Portfolio's load landed with part of what Total
    /// Volume is built from unread — a launchpad, the Moments, a past cohort, the prices (`PortfolioModel.error`; the
    /// Portfolio says the same, in full): the header's warning, so a Total Volume short of some trades is never taken for
    /// the whole, and one saved when last read in full, kept meanwhile (`PortfolioModel.showsLive`), is said to be beside
    /// why.
    private var volumeError: String? {
        env.portfolio.historyUnreachable || env.portfolio.error != nil
            ? tr("Part of your history couldn't be read just now, so some figures may be missing. Pull to refresh.") : nil
    }

    /// Total Volume for the period, right-aligned, with the period menu (24h · 7 days · 30 days · All) under it —
    /// the same figure the Portfolio breaks down by section. Tapping the number opens the Portfolio. Until the Portfolio
    /// has loaded and the chain history has been read at all, the figure saved when the wallet was last read in full,
    /// said to be ("Updated 3 hr ago", `volumeSavedAt`), else a placeholder (never "$0.00" ahead of it): the figure then
    /// follows the history as it fills in, said to be read on until the scans it is built from
    /// (`WalletHistoryScans.volume`) have read the period's own window — the last day long before the last month.
    private var totalVolume: some View {
        @Bindable var router = router
        let volume = shownVolume
        return VStack(alignment: .trailing, spacing: 4) {
            Button { Haptics.tap(); router.presented = .portfolio } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total Volume").font(.subheadline).foregroundStyle(.secondary)
                    Text(PriceFormat.usdValue(volume ?? 0))
                        .font(.headline).monospacedDigit().foregroundStyle(.primary)
                        .contentTransition(.numericText(value: volume ?? 0))
                        .unreadFigure(volume == nil)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Total volume \(router.period.label)")
            if let volumeSavedAt {
                // The saved figure says when it was read right under it: Home's own parts can all be read again while the
                // Portfolio's heavier load hasn't landed, and its line under the balance is theirs alone.
                SavedLine(date: volumeSavedAt, reading: env.portfolio.loading)
            } else if liveVolume, env.history.snapshot.read, env.portfolio.historyFilling(router.period, scans: WalletHistoryScans.volume) {
                // The figure follows the history as it fills in: how far the period's window has got, so a figure short
                // of older trades is never taken for the whole. Not before the store's instant read has landed (`read`):
                // the figure is a placeholder until then, and the line would flash "0%".
                Text("Reading your history… \(NumberStyle.percent(env.portfolio.historyProgress(router.period, scans: WalletHistoryScans.volume) * 100, fractionDigits: 0, signed: false))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Menu {
                Picker("Period", selection: $router.period) {
                    ForEach(VolumePeriod.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.caption2.weight(.semibold))
                    Text(router.period.label).font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .accessibilityLabel("Volume period")
        }
    }

    /// Total Volume shows the Portfolio's figure once its load has landed with the history's first read (`liveVolume`),
    /// unless that load left part of it unread while a figure saved when the wallet was last read in full stays
    /// (`PortfolioModel.showsLive`); until then the saved one (`PortfolioModel.savedTotals`), said to be under it
    /// (`volumeSavedAt`); else nil, a placeholder.
    private var liveVolume: Bool { env.portfolio.showsLive(router.period) && (session.address == nil || env.history.snapshot.anchor != nil) }
    private var shownVolume: Double? {
        liveVolume ? env.portfolio.totals(router.period).volume : env.portfolio.savedTotals(router.period)?.volume
    }

    /// When the saved Total Volume shown was read; nil while the figure is the Portfolio's load (`liveVolume`), or a
    /// placeholder.
    private var volumeSavedAt: Date? { liveVolume ? nil : env.portfolio.savedAt(router.period) }

    /// Said under the balance and its day's move while a part of the wallet shows what was saved when it was last read
    /// (`HomeModel.savedAt`), with a spinner while Home reads them again: a saved figure is never taken for a fresh one.
    /// Total Volume says its own under it (`volumeSavedAt`). In the balance's column, beside Total Volume's: while that
    /// column is the taller — Total Volume saying when its own saved figure was read, or how far the history has got, as
    /// on a warm launch, where Home's parts are read again first — the card keeps its height when the line goes, and
    /// nothing below it moves. Never animated (`HomeView.body`).
    private func savedLine(_ date: Date) -> some View {
        SavedLine(date: date, reading: model.loading)
    }

    /// `value` nil: the part it comes from isn't read for the wallet yet, so a placeholder (`unreadFigure`).
    private func statColumn(_ title: LocalizedStringKey, value: Double?, tint: Color, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(PriceFormat.usdValue(value ?? 0)).font(.headline).monospacedDigit().foregroundStyle(tint)
                .unreadFigure(value == nil)
        }
    }

    /// One of the four categories under the balance, named as My Holdings' switch names it. `value` nil: the category
    /// isn't read for the wallet yet (a failed read included), so a placeholder (`unreadFigure`).
    private func splitStat(_ category: HoldingCategory, _ value: Double?, _ dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(verbatim: category.label).font(.caption).foregroundStyle(.secondary)
            }
            Text(PriceFormat.usdValue(value ?? 0))
                .font(.subheadline.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .unreadFigure(value == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            HomeAction(title: "Bridge", symbol: "point.3.connected.trianglepath.dotted") { showBridge = true }
            HomeAction(title: "Deposit", symbol: "creditcard") { showReceive = true }
            HomeAction(title: "Withdraw", symbol: "arrow.up") { showSend = true }
            HomeAction(title: "Transfer", symbol: "arrow.left.arrow.right") { showTransfer = true }
        }
        .disabled(session.address == nil)
    }

    // MARK: Allocation

    /// Drawn once every part is read for the wallet (`HomeModel.split`), so no share is a part not read yet.
    private func allocationCard(_ split: HomeModel.Split) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allocation").font(.headline)
            AllocationDonut(
                segments: [
                    .init(label: tr("Spot"), value: split.spot, color: .allocationSpot),
                    .init(label: tr("Perps"), value: split.perps, color: .allocationPerps),
                    .init(label: tr("Launchpad"), value: split.launch, color: .allocationLaunchpad),
                    .init(label: tr("Moments"), value: split.moments, color: .allocationMoments),
                ],
                total: split.total
            )
        }
        .padding(16)
        .cardBackground()
    }

    // MARK: Top tokens

    private var topTokensCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Tokens").font(.headline)
            Picker("Filter", selection: $tokenTab) {
                ForEach(HomeTokenTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            let tokens = model.topTokens(tokenTab)
            if tokens.isEmpty {
                Text("Loading markets…").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(tokens.prefix(6).enumerated()), id: \.element.id) { index, row in
                        NavigationLink(value: pageRow(row)) { TokenListRow(rank: index + 1, row: row, rankWidth: rankWidth) }
                            .buttonStyle(.plain)
                        if index < min(5, tokens.count - 1) { Divider().padding(.leading, TokenListRow.textInset(rankWidth: rankWidth)) }
                    }
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    // MARK: Holdings

    private var holdingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("My Holdings").font(.headline)
                Spacer()
            }
            Picker("Category", selection: $holdingTab) {
                ForEach(HoldingCategory.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            // A tab says it holds none only once its part of the wallet was read (`HomeReadState`): before, a loading row,
            // or that it couldn't be read, with Retry.
            switch holdingTab {
            case .spot:
                if model.holdings.isEmpty {
                    if model.reads.hasFigures(.spot) { holdingsEmpty("No spot balances", "Buy or swap a token and it appears here.") }
                    else { holdingsUnreadRow(.spot, reading: "Reading your balances…") }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.holdings.enumerated()), id: \.element.id) { index, row in
                            NavigationLink(value: pageRow(row)) { HoldingRow(row: row, unverified: model.unverified.contains(row.id)) }.buttonStyle(.plain)
                            if index < model.holdings.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
                savedUnreadRow(.spot)
            case .perps:
                // The positions are never saved (only the equity is): "none" only once they were read in this session.
                if model.positions.isEmpty {
                    if model.reads.isRead(.perps) { holdingsEmpty("No open positions", "Open a perp from the Trade tab.") }
                    else { holdingsUnreadRow(.perps, reading: "Reading your positions…") }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.positions.enumerated()), id: \.element.id) { index, position in
                            Button { router.openPerp(id: position.perpId) } label: { PositionSummaryRow(position: position) }
                                .buttonStyle(.plain)
                            if index < model.positions.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
            case .launchpad:
                if model.launchHoldings.isEmpty {
                    if model.reads.hasFigures(.launch) { holdingsEmpty("No launch holdings", "Buy or launch a coin on the Launch tab.") }
                    else { holdingsUnreadRow(.launch, reading: "Reading your balances…") }
                } else {
                    VStack(spacing: 0) {
                        let totals = model.totals
                        ForEach(Array(model.launchHoldings.enumerated()), id: \.element.id) { index, holding in
                            // Every launch holding opens its own Launch page, never Swap: a coin still on a curve (the
                            // live launchpad's or a retired one's) trades there, and a graduated one's page leads to Swap.
                            Button { openLaunch(holding.launch) } label: { LaunchHoldingRow(holding: holding, value: totals.value(of: holding.id, units: holding.units)) }
                                .buttonStyle(.plain)
                            if index < model.launchHoldings.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                    // Read from the launchpads read so far, while one never has been, or saved when last read and not read
                    // since: the rest are said to be missing.
                    if model.reads.status(.launch) == .failed { holdingsRetryRow("Some launch coins couldn't be read just now — showing the last ones read.") }
                }
                if model.launchHoldings.isEmpty { savedUnreadRow(.launch) }
            case .moments:
                if model.momentRows.isEmpty {
                    if model.reads.hasFigures(.moments) { holdingsEmpty("No Moments yet", "Collect a Moment on the Moments tab and your editions and coins appear here.") }
                    else { holdingsUnreadRow(.moments, reading: "Reading your Moments…") }
                } else {
                    VStack(spacing: 0) {
                        let totals = model.totals
                        ForEach(Array(model.momentRows.enumerated()), id: \.element.id) { index, row in
                            Button { openMoment(row.moment) } label: { MomentHoldingRow(row: row, value: totals.value(of: row.moment.moment.coin, units: HomeModel.coins(row))) }
                                .buttonStyle(.plain)
                            if index < model.momentRows.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
                savedUnreadRow(.moments)
            }
        }
        .padding(16)
        .cardBackground()
    }

    /// The row a token's page opens with. While Spot shows what was saved when the wallet was last read
    /// (`HomeReadState.isSaved`), the token alone: the page reads its price and chart itself, and shows no balance not read
    /// in this session — a token page shows the row it is given as current.
    private func pageRow(_ row: MarketRow) -> MarketRow {
        model.reads.isSaved(.spot) ? MarketRow(token: row.token, usd: nil, change24h: nil, balance: 0) : row
    }

    /// A launch holding's page. One saved when the wallet was last read (`HomeReadState.isSaved`) opens by reference, so
    /// the page reads it now: a launch page shows the launch it is given as current — its price, its phase, which trades
    /// are open.
    private func openLaunch(_ launch: Launch) {
        if model.reads.isSaved(.launch) {
            router.openLaunch(LaunchReference(token: launch.token, factory: launch.factory))
        } else {
            router.openLaunch(launch)
        }
    }

    /// A Moment holding's page. One saved when the wallet was last read (`HomeReadState.isSaved`) opens by its link, so the
    /// page reads the Moment now (`MomentLinkView`): a Moment's page shows the Moment it is given as current — its state,
    /// its reserve, which actions are open.
    private func openMoment(_ moment: MomentInfo) {
        if model.reads.isSaved(.moments), let link = MomentLink(key: moment.key) {
            router.openMoment(link)
        } else {
            router.openMoment(moment)
        }
    }

    /// A part showing what was saved when it was last read whose read now failed (`HomeReadState.isSaved`, `.failed`):
    /// its saved figures stay, said to be saved above the balance, and the tab says the read failed, with Retry.
    @ViewBuilder private func savedUnreadRow(_ part: HomeReadState.Part) -> some View {
        if model.reads.isSaved(part), model.reads.status(part) == .failed {
            holdingsRetryRow(HomeModel.unreadMessage(part))
        }
    }

    private func holdingsEmpty(_ title: LocalizedStringKey, _ detail: LocalizedStringResource) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Paragraph(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    /// A tab whose part of the wallet isn't read yet (`HomeReadState`): a loading row while its first read runs, and once
    /// that failed, says so with Retry. Never "No … yet" for want of an answer.
    @ViewBuilder private func holdingsUnreadRow(_ part: HomeReadState.Part, reading: LocalizedStringKey) -> some View {
        if model.reads.status(part) == .failed {
            holdingsRetryRow(HomeModel.unreadMessage(part))
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(reading).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    /// A read that failed, said with Retry; a spinner in its place while Home reads again (the Retry, or its refresh).
    private func holdingsRetryRow(_ message: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline) {
            InlineError(message: message)
            Spacer(minLength: 8)
            if model.loading {
                ProgressView().controlSize(.small)
            } else {
                Button("Retry") { Task { await model.load(env: env, address: session.address) } }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Home building blocks

enum HomeTokenTab: String, CaseIterable, Identifiable {
    case popular, hot, gainers, losers
    var id: String { rawValue }
    var label: String {
        switch self {
        case .popular: return tr(LocalizedStringResource("Popular", comment: "Top Tokens tab: the curated list [tight]"))
        case .hot: return tr(LocalizedStringResource("Hot", comment: "Top Tokens tab: the biggest moves either way [tight]"))
        case .gainers: return tr(LocalizedStringResource("Gainers", comment: "Top Tokens tab: rising most in 24h [tight]"))
        case .losers: return tr(LocalizedStringResource("Losers", comment: "Top Tokens tab: falling most in 24h [tight]"))
        }
    }
}

enum HoldingCategory: String, CaseIterable, Identifiable {
    case spot, perps, launchpad, moments
    var id: String { rawValue }
    /// The category's name where four share Home's card: My Holdings' switch and the balance card's split. Keys of their
    /// own, apart from the tabs' and the menu's names, so a language whose tab names are long can keep these short.
    var label: String {
        switch self {
        case .spot: return tr(LocalizedStringResource("homeCategory.spot", defaultValue: "Spot", comment: "[tight] Home, one of four categories sharing the card's width: a segment of My Holdings' switch and a label over the balance card's split. The wallet's own tokens, as against Perps"))
        case .perps: return tr(LocalizedStringResource("homeCategory.perps", defaultValue: "Perps", comment: "[tight] Home, one of four categories sharing the card's width: a segment of My Holdings' switch and a label over the balance card's split. Perpetual futures"))
        case .launchpad: return tr(LocalizedStringResource("homeCategory.launch", defaultValue: "Launch", comment: "[tight] Home, one of four categories sharing the card's width: a segment of My Holdings' switch and a label over the balance card's split. The launchpad's coins (a noun), as the Launch tab"))
        case .moments: return tr(LocalizedStringResource("homeCategory.moments", defaultValue: "Moments", comment: "[tight] Home, one of four categories sharing the card's width: a segment of My Holdings' switch and a label over the balance card's split. The Moments feature's name"))
        }
    }
}

/// One of the four home actions: an SF Symbol over a label, filling its share of the row.
private struct HomeAction: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    /// One height for every symbol, so the four tiles and their labels line up: Transfer's arrows stand taller.
    @ScaledMetric(relativeTo: .body) private var symbolHeight: CGFloat = 24

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.body.weight(.semibold)).frame(height: symbolHeight)
                Text(title).font(.caption).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundStyle(.primary)
    }
}

/// The allocation ring: a donut of the value split with a centered total and a legend of shares.
struct AllocationDonut: View {
    struct Segment: Identifiable {
        let label: String
        let value: Double
        let color: Color
        var id: String { label }
    }

    let segments: [Segment]
    let total: Double

    private var hasValue: Bool { total > 0 && segments.contains { $0.value > 0 } }

    var body: some View {
        HStack(spacing: 20) {
            Chart(hasValue ? segments : placeholder) { segment in
                SectorMark(angle: .value("Value", segment.value), innerRadius: .ratio(0.66), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(segment.color)
            }
            .chartLegend(.hidden)
            .frame(width: 128, height: 128)
            .overlay {
                VStack(spacing: 1) {
                    Text("Total").font(.caption2).foregroundStyle(.secondary)
                    Text(PriceFormat.usdValue(total)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                .padding(.horizontal, 8)
            }

            VStack(spacing: 10) {
                ForEach(segments) { segment in
                    HStack(spacing: 8) {
                        Circle().fill(segment.color).frame(width: 9, height: 9)
                        Text(segment.label).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(NumberStyle.percent(hasValue ? segment.value / total * 100 : 0, fractionDigits: 1, signed: false))
                            .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var placeholder: [Segment] {
        segments.map { Segment(label: $0.label, value: 1, color: $0.color.opacity(0.28)) }
    }
}

/// A ranked market row for the Top Tokens list.
private struct TokenListRow: View {
    let rank: Int
    let row: MarketRow
    /// The rank column's width (`HomeView.rankWidth`).
    let rankWidth: CGFloat

    private static let spacing: CGFloat = 12
    private static let logoSize: CGFloat = 34

    /// Where the row's text starts, for the divider under it: rank, gap, logo, gap (74 pt at the default text size).
    static func textInset(rankWidth: CGFloat) -> CGFloat { rankWidth + spacing + logoSize + spacing }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(verbatim: "\(rank)").font(.footnote.monospacedDigit()).foregroundStyle(.tertiary).frame(width: rankWidth, alignment: .center)
            TokenLogo(token: row.token, size: Self.logoSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.token.symbol).font(.subheadline.weight(.semibold))
                    // Top Tokens lists no token the wallet was sent unasked (`HomeModel.topTokens`).
                    TokenBadgeView(token: row.token, receivedUnasked: false)
                }
                Text(row.token.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            USDText(price: row.usd, font: .subheadline.weight(.medium))
                .layoutPriority(1) // the price keeps its width; the name truncates first
            ChangeBadge(value: row.change24h)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A wallet holding row: logo, symbol + amount, value + 24h.
private struct HoldingRow: View {
    let row: MarketRow
    /// Found in the wallet's history, not chosen in the app (`KnownTokenStore.unverified`).
    var unverified = false

    var body: some View {
        HStack(spacing: 12) {
            TokenLogo(token: row.token, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.token.symbol).font(.subheadline.weight(.semibold))
                    TokenBadgeView(token: row.token, receivedUnasked: unverified)
                }
                AmountText(amount: row.balance, token: row.token, compact: true, font: .caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if row.notTradingYet {
                // A Moment still collecting: no pool yet, so no price, and no value to show.
                Text("Not trading yet").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    USDText(value: row.value, font: .subheadline.weight(.medium))
                    // Always surface the per-unit price next to the 24h change, even for tokens with a small balance.
                    HStack(spacing: 5) {
                        USDText(price: row.usd, font: .caption2).foregroundStyle(.secondary)
                        ChangeText(value: row.change24h, style: .caption2)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A launch-coin holding row: artwork, the held amount, and its USD value — the user's position, not the market cap —
/// at the price Home counts it at (`HomeTotals`), "—" without one.
private struct LaunchHoldingRow: View {
    let holding: HomeModel.LaunchHolding
    let value: Double?

    var body: some View {
        HStack(spacing: 12) {
            LaunchArtwork(symbol: holding.launch.symbol, logo: holding.launch.logo, pointSize: 34)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(holding.launch.symbol).font(.subheadline.weight(.semibold))
                Text(verbatim: "\(NumberStyle.units(holding.balance, decimals: 18, compact: true)) \(holding.launch.symbol)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                USDText(value: value, font: .subheadline.weight(.medium))
                (holding.launch.phase == .bonding ? Text("\(holding.launch.progressBps / 100)% to graduation") : Text(verbatim: holding.launch.phase.title))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A perps position summarised for the holdings list.
private struct PositionSummaryRow: View {
    let position: PerpPosition

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(position.symbol).font(.subheadline.weight(.semibold))
                    Text(verbatim: "\(sideLabel) \(NumberStyle.number(position.leverage, maximumFractionDigits: 1))×")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((position.side == .long ? Color.positive : Color.negative).opacity(0.15), in: Capsule())
                        .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                }
                Text("\(NumberStyle.number(position.size)) at \(NumberStyle.number(position.entry))", comment: "A perp position's size, then the price it was opened at")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(PriceFormat.usdValue(position.unrealized, signed: true))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                    .foregroundStyle(position.unrealized < 0 ? Color.negative : Color.positive)
                Text("Unrealized", comment: "Under a perp position's unrealized profit or loss [tight]").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// The position's side, for the chip beside its leverage ("Long 5×").
    private var sideLabel: String {
        position.side == .long
            ? tr(LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]"))
            : tr(LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]"))
    }
}

extension View {
    /// The standard grouped card: secondary surface, continuous corners, hairline separation from the ground.
    func cardBackground() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A figure not read yet (`unread`) — on Home, a part of the wallet; on My Launchpad, a stat, a holding's value or its
    /// profit and loss: drawn as the placeholder shape of one, and said by VoiceOver to be loading, never as the "$0.00"
    /// or "0" the shape is drawn from.
    @ViewBuilder func unreadFigure(_ unread: Bool) -> some View {
        if unread {
            redacted(reason: .placeholder)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Loading…"))
        } else {
            self
        }
    }
}

/// A token as the Home screen shows it: price, movement, and the signed-in wallet's balance. `info` is the price read as
/// it came (a DyorHQ coin's "vs MON", "New" and price source); `notTradingYet` marks a Moment still collecting, which
/// has no price yet. Codable: Home saves its rows as it last showed them (`HomeModel.Saved`).
struct MarketRow: Identifiable, Hashable, Codable {
    let token: Token
    let usd: Double?
    let change24h: Double?
    let balance: BigUInt
    var info: PriceInfo? = nil
    var notTradingYet = false
    var id: Address { token.address }
    var value: Double? { usd.map { Amount.units(balance, decimals: token.decimals) * $0 } }
}

@Observable
@MainActor
final class HomeModel {
    /// A launch coin the wallet holds (or created), with the Launch tab's price for it: Spot's, else its own decimal
    /// price (`DyorPrice.launch`); nil when neither is known.
    struct LaunchHolding: Identifiable, Hashable, Codable {
        let launch: Launch
        let balance: BigUInt
        let priceUSD: Double?
        var id: Address { launch.token }
        /// Whole coins held.
        var units: Double { Amount.units(balance, decimals: 18) }
        var valueUSD: Double? { priceUSD.map { units * $0 } }
    }

    /// Home's four parts as the balance card splits them, once each of them can be told (`HomeReadState.showsValue`).
    struct Split: Hashable {
        let spot: Double
        let perps: Double
        let launch: Double
        let moments: Double
        var total: Double { spot + perps + launch + moments }
    }

    private(set) var rows: [MarketRow] = []
    private(set) var launches: [Launch] = []
    private(set) var launchHoldings: [LaunchHolding] = []
    private(set) var positions: [PerpPosition] = []
    /// The Perpl account's equity: 0 without an account, nil until it is read for the wallet (never taken for 0).
    private(set) var perpEquity: Double?
    /// The wallet's Moments stakes (editions, entitlements, coins), valued at each graduated pool's price.
    private(set) var momentRows: [MomentPortfolioRow] = []
    /// How far each part of the wallet has been read for it (`HomeReadState`): a figure from a part not read yet is nil,
    /// a placeholder on screen, and its holdings tab shows a loading row, or says it couldn't be read, with Retry.
    private(set) var reads = HomeReadState()
    private(set) var loading = false
    private(set) var error: String?
    private(set) var updatedAt: Date?
    /// Tokens the wallet was sent rather than chose (`KnownTokenStore.unverified`): marked in holdings, and never
    /// ranked in Top Tokens.
    private(set) var unverified: Set<Address> = []
    /// When each part on screen was read for the wallet: in this session (`record`), or, for a part still showing what was
    /// saved, when that was read (`restoreSaved`). What Home saves carries these times (`save`). Not observed: `savedAt`
    /// changes only with `reads`, which is.
    @ObservationIgnored private var readAt: [HomeReadState.Part: Date] = [:]
    /// Whose data the model holds.
    private var loadedFor: Address?
    /// The launchpads whose launches have been read at least once, whoever is signed in (as `launches`, which they fill):
    /// one that couldn't be read keeps only the launches an earlier read found (`LaunchListing.keeping`), so the Launch
    /// tab is read in full only once every launchpad has been. Only reads in this session count: `launches` taken from a
    /// saved Home empties it (`restoreSaved`).
    @ObservationIgnored private var listedFactories: Set<Address> = []
    /// The registry taking in the coins of the launches and Moments the last load read (`DyorCoinsModel.ingest`).
    @ObservationIgnored private var ingesting: Task<Void, Never>?

    var holdings: [MarketRow] { rows.filter { $0.balance > 0 }.sorted { ($0.value ?? 0) > ($1.value ?? 0) } }

    /// When the oldest part still showing what was saved for the wallet was read (`restoreSaved`): Home says it ("Updated
    /// 3 min ago") until every part on screen was read in this session, and then this is nil.
    var savedAt: Date? { HomeReadState.Part.allCases.filter { reads.isSaved($0) }.compactMap { readAt[$0] }.min() }

    /// Spot, Launch and Moments with every address counted once (`HomeTotals`): a DyorHQ coin stays listed in Spot but
    /// counts under Launch or Moments when that tab lists it, at the one price Spot shows for it.
    var totals: HomeTotals {
        HomeTotals(spot: holdings.map { HomeTotals.Line(address: $0.id, units: Amount.units($0.balance, decimals: $0.token.decimals), price: $0.usd) },
                   launch: launchHoldings.map { HomeTotals.Line(address: $0.id, units: $0.units, price: $0.priceUSD) },
                   moments: momentRows.map { HomeTotals.Line(address: $0.moment.moment.coin, units: Self.coins($0), price: WalletHoldings.momentPrice($0.moment)) })
    }

    /// A Moments stake's coins: held, plus still owed (entitled, not yet claimed).
    nonisolated static func coins(_ row: MomentPortfolioRow) -> Double {
        let owed = row.entitlement > row.claimed ? row.entitlement - row.claimed : 0
        return MomentsMath.coins(row.coinBalance) + MomentsMath.coins(owed)
    }

    // Each part's figure is nil until it can be told for the wallet (`HomeReadState.showsValue`): a placeholder on
    // screen, never "$0.00" for want of an answer.

    /// The tokens no other tab counts (`HomeTotals.spot`), once the Launch and Moments tabs are read too.
    var spotValue: Double? { reads.showsValue(of: .spot) ? totals.spot : nil }
    /// The Perpl account's equity, 0 without one; nil while it is unread, a failed read included.
    var perpsValue: Double? { reads.showsValue(of: .perps) ? perpEquity : nil }
    /// Value of the launch coins the Launch tab lists. Feeds the allocation ring and total.
    var launchpadValue: Double? { reads.showsValue(of: .launch) ? totals.launch : nil }
    /// Value of the wallet's Moment coins (held plus still owed) at Spot's price or each pool's live one; a Moment with no
    /// market yet counts at zero.
    var momentsValue: Double? { reads.showsValue(of: .moments) ? totals.moments : nil }
    var availableBalance: Double? { spotValue }
    var inUse: Double? { perpsValue }

    /// The four parts' figures, once every one of them can be told: the allocation ring's shares and the total.
    var split: Split? {
        guard let spot = spotValue, let perps = perpsValue, let launch = launchpadValue, let moments = momentsValue else { return nil }
        return Split(spot: spot, perps: perps, launch: launch, moments: moments)
    }

    /// Everything the wallet holds: nil until every part is read for it, so a total short of one is never shown.
    var totalValue: Double? { split?.total }

    /// Value-weighted 24h change of the wallet, when every priced holding has a change.
    var change24h: Double? {
        let priced = holdings.filter { $0.value != nil && $0.change24h != nil }
        let total = priced.compactMap(\.value).reduce(0, +)
        guard total > 0 else { return nil }
        return priced.reduce(0) { $0 + ($1.value! / total) * $1.change24h! }
    }

    /// Top-tokens list per tab. Popular keeps the curated order; the movers sort by 24h change; hot ranks by the
    /// strength of the move in either direction (a stand-in for volume, which the price service does not surface).
    func topTokens(_ tab: HomeTokenTab) -> [MarketRow] {
        let priced = rows.filter { $0.usd != nil && !unverified.contains($0.id) }
        switch tab {
        case .popular: return priced
        case .hot: return priced.sorted { abs($0.change24h ?? 0) > abs($1.change24h ?? 0) }
        case .gainers: return priced.filter { ($0.change24h ?? 0) > 0 }.sorted { ($0.change24h ?? 0) > ($1.change24h ?? 0) }
        case .losers: return priced.filter { ($0.change24h ?? 0) < 0 }.sorted { ($0.change24h ?? 0) < ($1.change24h ?? 0) }
        }
    }

    /// The wallet and the state of its transfer history the tokens were last read for (`discoverHeldTokens`).
    private var discoveredFor: String?

    func poll(env: AppEnvironment, address: Address?) async {
        while !Task.isCancelled {
            await load(env: env, address: address)
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// Finds ERC-20s the wallet holds on-chain that aren't in its universe yet (received outside the app, airdropped,
    /// bridged), persists them to the shared token store as Unverified, and reloads — so every held token appears in
    /// holdings, marked, while the swap picker lists it only when searched for (IOST-12). Runs once per wallet; the
    /// persisted tokens then price and balance like any curated asset.
    /// The tokens the wallet's history shows it received, from the history model's transfers (no scan of its own): read
    /// again as the history fills in, and once more after it is complete.
    func discoverHeldTokens(env: AppEnvironment, address: Address?) async {
        guard let address, address == env.history.wallet else { return }
        let snapshot = env.history.snapshot
        let stage = "\(address.hex)-\(snapshot.transfersIn.count)-\(snapshot.status(WalletHistoryScans.transfersInId).complete)"
        guard discoveredFor != stage else { return }
        let known = Set(KnownTokenStore.universe(owner: address).map(\.address))
        let found = await env.walletDiscovery.held(wallet: address, incoming: snapshot.transfersIn, complete: snapshot.status(WalletHistoryScans.transfersInId).complete, known: known).tokens
        // Cut short (the history moved on meanwhile): read again at its next move, never skipped for good.
        guard !Task.isCancelled else { return }
        discoveredFor = stage
        guard !found.isEmpty else { return }
        // Give each discovered token an accurate logo from Kuru's directory (the venues don't serve icons).
        let logos = await env.kuruTokens.logos()
        for token in found {
            let enriched = token.logoURL == nil && logos[token.address] != nil
                ? Token(address: token.address, symbol: token.symbol, name: token.name, decimals: token.decimals, logoURL: logos[token.address], isLaunchpad: token.isLaunchpad)
                : token
            KnownTokenStore.addDiscovered(enriched, owner: address)
        }
        await load(env: env, address: address)
    }

    /// Takes in `address` before Home's first frame (`HomeView`'s `onAppear`) and at the start of every load: another
    /// account's figures go, and what was saved for this one when it was last read — a small file on the device, read on
    /// the spot — shows at once, each part said to be saved until its own read replaces it (`restoreSaved`). So a warm
    /// launch opens on the wallet's figures rather than on placeholders until the first load's task starts.
    func showSaved(env: AppEnvironment, address: Address?) {
        // Another account: nothing of the previous one's may stay on screen, even when a read below fails. What was saved
        // for this one when it was last read shows at once instead, each part said to be saved until its own read below
        // replaces it (`restoreSaved`).
        if address != loadedFor {
            rows = []; launchHoldings = []; positions = []; perpEquity = nil; momentRows = []; updatedAt = nil; reads = HomeReadState(); readAt = [:]
            loadedFor = address
            restoreSaved(env: env, address: address)
        }
    }

    func load(env: AppEnvironment, address: Address?) async {
        loading = true
        defer { loading = false }
        // Already done before Home's first frame (`showSaved`), unless the account changed since.
        showSaved(env: env, address: address)
        // What this load reads is saved only while this device's data isn't erased meanwhile (`SavedScreens.epoch`).
        let epoch = env.savedScreens.epoch
        // The curated list plus anything the wallet has acquired (swapped into, launched), so held tokens like an
        // RWA or a launched coin still show up with a balance and a price.
        let tokens = KnownTokenStore.universe(owner: address).filter { $0.symbol != "WMON" }
        // The tokens the wallet was sent rather than chose, as the device has them now: the rows published below are
        // marked with them; the coins it made are taken out once the registry has read them (after the reads).
        unverified = KnownTokenStore.unverified(owner: address)
        // Each part is published as its own read lands, never held back by the slowest (`publishSpot`, `publishLaunch`,
        // `publishPerps`, `publishMoments`): its tab and its figure in the split fill in one by one. A load cancelled
        // part-way (the screen went away, the account changed) publishes nothing more (security audit 2026-09-26, RS-10):
        // what the rest of its reads answer is dropped.
        var priceMap: [Address: PriceInfo]?
        var priceError: Error?
        var notTrading: Set<Address> = []
        var pricesIn = false
        var balanceMap: [Address: BigUInt]?
        var balancesIn = false
        var listing: LaunchListing?
        var launchList: [Launch] = []
        var holdingsAsked = false
        var momentState: [MomentPortfolioRow]?
        await withTaskGroup(of: Answer.self) { group in
            // Which of them are DyorHQ coins, from their factories (MON, the curated tokens and coins already known cost
            // nothing): their pictures and labels, and the wallet's own coins below.
            group.addTask { await env.dyorCoins.prove(tokens); return .proven }
            group.addTask { await Self.readPrices(env: env, tokens: tokens) }
            group.addTask { .balances(await self.walletBalances(env: env, address: address, tokens: tokens)) }
            group.addTask { .listing(await env.launchpad.launchListing(limit: 30)) }
            group.addTask { .perps(await self.loadPerps(env: env, address: address)) }
            group.addTask { .moments(await self.loadMoments(env: env, address: address)) }
            while let answer = await group.next() {
                let stands = !Task.isCancelled && address == loadedFor
                switch answer {
                case .proven:
                    break
                case let .prices(map, error, collecting):
                    priceMap = map; priceError = error; notTrading = collecting; pricesIn = true
                    if stands, balancesIn { publishSpot(tokens: tokens, priceMap: priceMap, balanceMap: balanceMap, notTrading: notTrading) }
                case .balances(let map):
                    balanceMap = map; balancesIn = true
                    if stands, pricesIn { publishSpot(tokens: tokens, priceMap: priceMap, balanceMap: balanceMap, notTrading: notTrading) }
                case .listing(let read):
                    listing = read
                    // A launchpad whose launches couldn't be read keeps its last good ones, and the screen says so.
                    launchList = read.keeping(self.launches)
                    if stands {
                        listedFactories.formUnion(read.factories.filter { read.unread[$0] == nil })
                        self.launches = launchList
                    }
                case .launchHoldings(let holdings):
                    if stands, let listing { publishLaunch(holdings, priceMap: priceMap, listing: listing) }
                case .perps(let state):
                    if stands { publishPerps(state) }
                case .moments(let state):
                    momentState = state
                    if stands { publishMoments(state) }
                }
                // The launch coins once the launches and the prices that value them are in: one balance read over them.
                // Without prices they can't be valued, so the part isn't read, and keeps what it showed.
                if stands, !holdingsAsked, pricesIn, let listing {
                    holdingsAsked = true
                    if let priceMap {
                        let launches = launchList
                        group.addTask { .launchHoldings(await self.loadLaunchHoldings(env: env, address: address, launches: launches, priceMap: priceMap)) }
                    } else {
                        publishLaunch(nil, priceMap: nil, listing: listing)
                    }
                }
            }
        }
        // The registry takes in the coins of the launches and Moments just read without holding the rows back: their
        // pictures and labels follow once they are proven, as the coins model re-renders the rows. One at a time, so a
        // slow node never stacks them up across refreshes.
        if ingesting == nil {
            let readLaunches = launchList
            let readMoments = momentState?.map(\.moment) ?? []
            ingesting = Task {
                await env.dyorCoins.ingest(readLaunches)
                await env.dyorCoins.ingest(readMoments)
                ingesting = nil
            }
        }
        let ownCoins = address == nil ? [] : await env.dyorCoins.created(by: address ?? .zero)
        // A read that failed keeps what the last good one showed, and says so; a load cancelled part-way (the screen
        // went away, the account changed) publishes nothing more (security audit 2026-09-26, RS-10).
        guard !Task.isCancelled, address == loadedFor, let listing else { return }
        // The coins the registry says this wallet made are its own, not Unverified: recorded as chosen through the helper
        // the Portfolio and the Send sheet use (`WalletTokens.markOwnCoins`). A coin it was only sent stays Unverified, out
        // of Top Tokens (IOST-12).
        if let address { WalletTokens.markOwnCoins(ownCoins, among: tokens, owner: address) }
        unverified = KnownTokenStore.unverified(owner: address)
        if let priceError {
            error = describe(priceError)
        } else if balanceMap == nil {
            // Balances to show — read in this session, or saved when the wallet was last read, said to be — are the last
            // ones read; with none, there are no last ones to show.
            error = reads.hasFigures(.spot) ? tr("Your balances couldn't be read just now — showing the last ones read.") : tr("Your balances couldn't be read. Check your connection and try again.")
        } else if !listing.complete {
            error = tr("Some launch coins couldn't be read just now — showing the last ones read.")
        } else if let part = reads.failed.first {
            // A part not read for the wallet yet: its tab says so, with Retry, and the total waits for it.
            error = tr(Self.unreadMessage(part))
        } else {
            error = nil
            updatedAt = .now
        }
        save(env: env, address: address, epoch: epoch)
    }

    /// One of `load`'s reads, as it answers.
    private enum Answer: Sendable {
        case proven
        /// The prices, the Moments still collecting among the tokens (when the prices were read), or why they weren't.
        case prices([Address: PriceInfo]?, Error?, Set<Address>)
        case balances([Address: BigUInt]?)
        case listing(LaunchListing)
        case launchHoldings([LaunchHolding]?)
        case perps((positions: [PerpPosition], equity: Double)?)
        case moments([MomentPortfolioRow]?)
    }

    /// The prices of `tokens`, and the Moments still collecting among them as the read just made found them: "Not trading
    /// yet" in place of a price. The error when the prices couldn't be read.
    private static func readPrices(env: AppEnvironment, tokens: [Token]) async -> Answer {
        do {
            let map = try await env.prices.prices(for: tokens)
            return .prices(map, nil, await env.prices.notTradingYet(tokens))
        } catch {
            return .prices(nil, error, [])
        }
    }

    /// One read of `part` answered for the wallet (`answered`), or failed (`HomeReadState.record`); set only when it
    /// changed, so an unchanged refresh doesn't redraw what follows it. An answer is dated, for what Home saves.
    private func record(_ part: HomeReadState.Part, answered: Bool) {
        var next = reads
        next.record(part, answered: answered)
        if next != reads { reads = next }
        if answered { readAt[part] = .now }
    }

    /// Spot, once the prices and the balances have both answered: read when both were, and the rows priced again whenever
    /// the prices were (a token whose balance couldn't be read keeps its last one).
    private func publishSpot(tokens: [Token], priceMap: [Address: PriceInfo]?, balanceMap: [Address: BigUInt]?, notTrading: Set<Address>) {
        record(.spot, answered: priceMap != nil && balanceMap != nil)
        guard let priceMap else { return }
        let previous = Dictionary(rows.map { ($0.id, $0.balance) }, uniquingKeysWith: { first, _ in first })
        rows = tokens.map { token in
            // A price that isn't a positive number is none: the row shows "—", never "$0.00".
            let info = priceMap[token.address].flatMap { DyorPrice.valid($0.usd) != nil ? $0 : nil }
            return MarketRow(token: token, usd: info?.usd, change24h: info?.change24h,
                             balance: balanceMap?[token.address] ?? previous[token.address] ?? 0, info: info, notTradingYet: notTrading.contains(token.address))
        }
    }

    /// The launch coins, read over every launchpad's launches and valued at the prices: read only when the balances and
    /// the prices were, and every launchpad's launches have been.
    private func publishLaunch(_ holdings: [LaunchHolding]?, priceMap: [Address: PriceInfo]?, listing: LaunchListing) {
        record(.launch, answered: holdings != nil && priceMap != nil && listing.factories.allSatisfy(listedFactories.contains))
        if let holdings, priceMap != nil { launchHoldings = holdings } // valued at the pair's price: not without one
    }

    private func publishPerps(_ state: (positions: [PerpPosition], equity: Double)?) {
        record(.perps, answered: state != nil)
        if let state {
            positions = state.positions
            perpEquity = state.equity
        }
    }

    private func publishMoments(_ state: [MomentPortfolioRow]?) {
        record(.moments, answered: state != nil)
        if let state { momentRows = state }
    }

    // MARK: Saved

    /// What Home saves for a wallet (`SavedScreens.Screen.home`): each part it had figures of, and when each was read
    /// (`readAt`). Perps is the account's equity only: its positions are read every time.
    struct Saved: Codable, Sendable {
        var rows: [MarketRow]?
        /// The launches the Launch part was read over: a launchpad that can't be read next time keeps these.
        var launches: [Launch]
        var launchHoldings: [LaunchHolding]?
        var momentRows: [MomentPortfolioRow]?
        var perpEquity: Double?
        var readAt: [HomeReadState.Part: Date]
    }

    /// What Home saved for `address` when it was last read (`SavedScreens`), shown at once: each part read under a day ago
    /// shows its figures, said to be saved (`HomeReadState.showSaved`, `savedAt`), until its own read replaces it. Nothing
    /// of another wallet's: the file is the wallet's own, and says so.
    private func restoreSaved(env: AppEnvironment, address: Address?) {
        guard let address, let saved = env.savedScreens.load(Saved.self, .home, wallet: address)?.value else { return }
        let now = Date()
        var parts: Set<HomeReadState.Part> = []
        for (part, at) in saved.readAt where SavedScreens.isShowable(savedAt: at, now: now) {
            switch part {
            case .spot:
                guard let rows = saved.rows else { continue }
                self.rows = rows
            case .perps:
                guard let equity = saved.perpEquity else { continue }
                perpEquity = equity
            case .launch:
                guard let holdings = saved.launchHoldings else { continue }
                launchHoldings = holdings
                // The launches a launchpad that can't be read keeps (`LaunchListing.keeping`) are this session's once it
                // has read any (another wallet's launches are the same chain's). The saved ones, up to a day old, only
                // while none has been listed, and then no launchpad counts as listed until a read of it lands here
                // (`listedFactories`): a part kept from the copy stays saved, said to be, opens its coins by reference, and
                // is saved again with its first time — never counted as read in this session.
                if launches.isEmpty {
                    launches = saved.launches
                    listedFactories = []
                }
            case .moments:
                guard let rows = saved.momentRows else { continue }
                momentRows = rows
            }
            parts.insert(part)
            readAt[part] = min(at, now)
        }
        reads.showSaved(parts)
    }

    /// Saves each part Home has figures of for the wallet, with when it was read: in this session, or still the saved one,
    /// which keeps its first time (a part is never said to be newer than its read). A part with none is left out, and
    /// opens unread next time. Dropped when this device's data was erased since the load began (`epoch`).
    private func save(env: AppEnvironment, address: Address?, epoch: Int) {
        guard let address else { return }
        let times = readAt.filter { reads.hasFigures($0.key) }
        guard let newest = times.values.max() else { return }
        let saved = Saved(rows: times[.spot] == nil ? nil : rows, launches: times[.launch] == nil ? [] : launches,
                          launchHoldings: times[.launch] == nil ? nil : launchHoldings, momentRows: times[.moments] == nil ? nil : momentRows,
                          perpEquity: times[.perps] == nil ? nil : perpEquity, readAt: times)
        env.savedScreens.save(saved, .home, wallet: address, savedAt: newest, epoch: epoch)
    }

    /// The wallet's Moments stakes, or nil when they couldn't be read.
    private func loadMoments(env: AppEnvironment, address: Address?) async -> [MomentPortfolioRow]? {
        guard let address, env.config.moments.isDeployed else { return [] }
        return (try? await env.moments.portfolio(account: address, limit: 100))?.rows
    }

    /// The wallet's balances of `tokens`, or nil when they couldn't be read (never read as zero).
    private func walletBalances(env: AppEnvironment, address: Address?, tokens: [Token]) async -> [Address: BigUInt]? {
        guard let address else { return [:] }
        return try? await ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall)
    }

    /// The wallet's launch-coin balances (and coins it created), each valued at the curve price × the pair asset's
    /// USD price, in one balanceOf multicall over the recent launches; nil when the balances couldn't be read.
    private func loadLaunchHoldings(env: AppEnvironment, address: Address?, launches: [Launch], priceMap: [Address: PriceInfo]) async -> [LaunchHolding]? {
        guard let address, !launches.isEmpty else { return [] }
        let tokens = launches.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        guard let balances = try? await ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall) else { return nil }
        return launches.compactMap { launch -> LaunchHolding? in
            let balance = balances[launch.token] ?? 0
            let created = launch.deployer == address
            // A coin the wallet created shows at a zero balance only while the board lists it: a retired launchpad's
            // sell-only coin shows only while held (owner decision 2026-09-29).
            guard balance > 0 || (created && launch.listsOnBoard) else { return nil }
            let pairUSD = launch.pair.isNative ? priceMap[Monad.native]?.usd : priceMap[launch.pairToken]?.usd
            return LaunchHolding(launch: launch, balance: balance, priceUSD: DyorPrice.launch(launch, spot: priceMap[launch.token]?.usd, pairUSD: pairUSD))
        }
        .sorted { ($0.valueUSD ?? 0) > ($1.valueUSD ?? 0) }
    }

    /// What a part's holdings tab says when no read of it has answered for the wallet and the last one failed
    /// (`HomeReadState.Status.failed`); the header's warning says it too.
    static func unreadMessage(_ part: HomeReadState.Part) -> LocalizedStringResource {
        switch part {
        case .spot: return LocalizedStringResource("Your tokens couldn't be read just now.", comment: "Home, My Holdings' Spot tab before anything was read: the wallet's token balances or their prices couldn't be read. A Retry button follows")
        case .perps: return LocalizedStringResource("Your Perpl account couldn't be read just now.", comment: "Home, My Holdings' Perps tab before anything was read: the wallet's Perpl trading account (equity and positions) couldn't be read. A Retry button follows")
        case .launch: return LocalizedStringResource("Your launch coins couldn't be read just now.", comment: "Home, My Holdings' Launch tab before anything was read: the launchpad coins the wallet holds couldn't be read. A Retry button follows")
        case .moments: return LocalizedStringResource("Your Moments couldn't be read just now.", comment: "Home, My Holdings' Moments tab before anything was read: the wallet's Moments editions and coins couldn't be read. A Retry button follows")
        }
    }

    /// The Perpl account's positions and equity: none and 0 without an account, nil when a read failed (never read as 0).
    private func loadPerps(env: AppEnvironment, address: Address?) async -> (positions: [PerpPosition], equity: Double)? {
        guard let address else { return ([], 0) }
        let found: PerpAccount?
        do { found = try await env.perpl.account(address) } catch { return nil }
        guard let account = found else { return ([], 0) }
        guard let markets = try? await env.perpl.markets(), let positions = try? await env.perpl.positions(account, markets: markets) else { return nil }
        let equity = Amount.units(account.balance, decimals: Perpl.collateralDecimals) + positions.reduce(0) { $0 + $1.unrealized }
        return (positions, equity)
    }
}

/// Price, 24h chart from on-chain history, and the actions that make sense for a token.
struct TokenDetailView: View {
    let row: MarketRow
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(Session.self) private var session
    @State private var history: [PricePoint] = []
    @State private var loadingHistory = true
    /// Where the coin trades (`LaunchpadService.curveRoute(for:)`): Swap, or, while it is still on a launchpad's bonding
    /// curve (the live launchpad's or a retired one's), its Launch page, since no Swap venue routes a curve. Nil until
    /// read; `.unchecked` when the check failed, which keeps Swap and offers to check again.
    @State private var curveRoute: CurveRoute?
    @State private var checkingCurve = false
    /// The price read by the page itself, for a token Home's list didn't price (one opened from search, or a Moment Home
    /// last saw collecting).
    @State private var loaded: PriceInfo?
    /// Whether the page's own read found its Moment still collecting; nil until it has read, and Home's mark stands.
    @State private var loadedNotTrading: Bool?

    /// The price as shown: Home's read, else the page's own (`loaded`).
    private var info: PriceInfo? { row.info ?? loaded }
    private var price: Double? { row.usd ?? loaded.flatMap { DyorPrice.valid($0.usd) } }
    private var change: Double? { row.usd != nil ? row.change24h : loaded?.change24h }
    /// A Moment still collecting: no price and no chart, "Not trading yet" in their place. The page's own read decides
    /// once it has one, so a Moment that graduated since Home's read shows its price.
    private var notTradingYet: Bool { loadedNotTrading ?? row.notTradingYet }

    /// Sent to the wallet rather than chosen in the app (`KnownTokenStore.unverified`).
    private var received: Bool { KnownTokenStore.isUnverified(row.token.address, owner: session.address) }
    /// Its label (`TokenBadge`): a DyorHQ coin's, a look-alike's warning, Unverified, or none.
    private var badge: TokenBadge { env.dyorCoins.badge(row.token, receivedUnasked: received) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        TokenLogo(token: row.token, size: 44)
                        if notTradingYet {
                            Text("Not trading yet").font(.system(.title2, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                USDText(price: price, font: .system(.largeTitle, design: .rounded).weight(.semibold))
                                if info?.isNew == true { NewBadge() } else { ChangeBadge(value: change) }
                            }
                        }
                    }
                    // A DyorHQ coin: its move against its pair asset, then where its price comes from.
                    if !notTradingYet, let pairChange = info?.pairChangeText {
                        Text(pairChange).font(.footnote.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if !notTradingYet, let source = info?.sourceLine {
                        Text(source).font(.footnote).foregroundStyle(.secondary)
                    }
                    if notTradingYet {
                        Paragraph("Its Moment hasn't graduated yet, so the coin has no market. It trades once the Moment graduates.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Past 24 hours").font(.footnote).foregroundStyle(.secondary)
                        PriceChart(points: history, isLoading: loadingHistory, tint: (change ?? 0) < 0 ? Color.negative : Color.positive)
                            .frame(height: 180)
                    }
                }
                .padding(.vertical, 6)
            }
            if badge.isImitation, let title = badge.title {
                // A look-alike keeps its warning, whatever made it (a DyorHQ launch called USDC included).
                Section {
                    Label(title, systemImage: "exclamationmark.shield").font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
                    Paragraph("This token carries the name of another token but is a different contract. Check the contract below before you trade it, and never follow a link or site its name points to.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if badge.isDyorHQ, let coin = env.dyorCoins.coin(row.token.address) {
                launchedOnDyorHQ(coin)
            } else if received || badge == .unverified {
                Section {
                    Label("Unverified token", systemImage: "exclamationmark.shield").font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
                    Text(received
                         ? "This token arrived in your wallet without you choosing it in DyorHQ. Anyone can send any token to any wallet, with any name — including a real token's. Check the contract below before you trade it, and never follow a link or site its name points to."
                         : "This token's name or symbol has characters that can make it read as another. Check the contract below before you trade it, and never follow a link or site its name points to.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if row.balance > 0 {
                Section("Your Balance") {
                    LabeledContent("Amount") { AmountText(amount: row.balance, token: row.token) }
                    LabeledContent("Value") {
                        if notTradingYet { Text("Not trading yet").foregroundStyle(.secondary) } else { USDText(value: price.map { Amount.units(row.balance, decimals: row.token.decimals) * $0 }) }
                    }
                }
            }
            Section("About") {
                LabeledContent("Name", value: row.token.displayName)
                if !row.token.isNative { AddressRow(title: "Contract", address: row.token.address) }
                LabeledContent("Decimals", value: String(row.token.decimals))
            }
            Section {
                if !SwapEngine.isTradable(row.token) {
                    // A retired cohort's Moment coin: past cohorts are claim-only, so no swap is offered.
                    Label("Past cohort · trading closed", systemImage: "lock").foregroundStyle(.secondary)
                } else if let route = curveRoute, route.isOnCurve, let title = route.actionTitle(row.token.symbol) {
                    // Never Swap: no venue routes a coin still on a launchpad's curve, live or retired. Its curve trades
                    // on its Launch page (Buy and Sell on the live launchpad, Sell only on a retired one), opened by
                    // reference when its launch couldn't be read.
                    Button(title, systemImage: "arrow.up.right.circle") { router.openLaunchPage(for: route) }
                } else {
                    Button("Swap \(row.token.symbol)", systemImage: "arrow.left.arrow.right") {
                        router.openSwap(tokenIn: row.token.symbol == "USDC" ? Token.mon : Token.usdc, tokenOut: row.token)
                    }
                    if curveRoute == .unchecked {
                        // The check failed: Swap stays, and so does the way to find out where the coin trades.
                        Button("Check Again", systemImage: "arrow.clockwise") { Task { await checkCurve() } }
                            .disabled(checkingCurve)
                    }
                }
                if let url = row.token.isNative ? nil : Monad.explorerToken(row.token.address) {
                    Link(destination: url) { Label("View on Monadscan", systemImage: "safari") }
                }
            } footer: {
                if SwapEngine.isTradable(row.token), let notice = curveRoute?.notice { Paragraph(notice) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(row.token.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A token Home's list didn't price (opened from search, or a Moment Home last saw collecting) is priced here,
            // once: a Moment that graduated since shows its price and chart.
            if row.usd == nil {
                loaded = (try? await env.prices.prices(for: [row.token]))?[row.token.address]
                loadedNotTrading = await env.prices.notTradingYet([row.token]).contains(row.token.address)
            }
            if !notTradingYet { history = (try? await env.prices.history(for: row.token, points: 48)) ?? [] }
            loadingHistory = false
        }
        .task(id: row.token.address) { await checkCurve() }
    }

    /// Where a DyorHQ coin was made, from its factory's record (`DyorCoinsModel`): a launchpad or a Moments cohort, live
    /// or retired, the launch's phase once known (`curveRoute`), its creator, and a way to its Launch page or its Moment.
    /// It stands in for the Unverified card: a DyorHQ coin sent to the wallet is labelled for what it is, and anyone can
    /// launch one, which the footer says.
    private func launchedOnDyorHQ(_ coin: DyorCoin) -> some View {
        Section {
            LabeledContent("Made on", value: coin.isMoment ? (coin.retired ? tr("A past Moments cohort") : tr("DyorHQ Moments")) : (coin.retired ? tr("A retired DyorHQ launchpad") : tr("The DyorHQ launchpad")))
            if let phase = launchPhase { LabeledContent("Phase", value: phase.title) }
            AddressRow(title: "Creator", address: coin.creator)
            if let key = coin.momentKey {
                if let link = MomentLink(key: key) {
                    Button("Open the Moment", systemImage: "photo.on.rectangle") {
                        router.pendingMomentLink = link
                        router.tab = .moments
                    }
                }
            } else {
                Button("Open the Launch Page", systemImage: "arrow.up.right.circle") {
                    if let launch = curveRoute?.launch { router.openLaunch(launch) } else { router.openLaunch(LaunchReference(token: coin.address, factory: coin.factory)) }
                }
            }
        } header: {
            Text("Launched on DyorHQ")
        } footer: {
            Paragraph("Anyone can launch a coin or publish a Moment on DyorHQ: this says where the coin was made, not that DyorHQ vouches for it.")
        }
    }

    /// A launch coin's phase, when the curve check read it: its launch's, or its factory's record's.
    private var launchPhase: LaunchPhase? {
        switch curveRoute {
        case .launchPage(let launch): return launch.phase
        case .launchUnread(_, _, let phase): return phase
        default: return nil
        }
    }

    /// Asks whether the coin is still on a launchpad's curve, and where it trades (one read of every known factory's
    /// record, then its launch). A graduated coin, or one no known launchpad launched, trades on Swap.
    private func checkCurve() async {
        checkingCurve = true
        defer { checkingCurve = false }
        let route = await env.launchpad.curveRoute(for: row.token)
        if Task.isCancelled { return }
        curveRoute = route
    }
}

/// "New" in place of a 24h change: a DyorHQ coin its factory hadn't recorded 24 hours ago (`PriceInfo.isNew`).
private struct NewBadge: View {
    var body: some View {
        Text("New", comment: "A badge on a new coin: just launched, or too new to have a 24h change [tight]")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.brand.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.brand)
    }
}

struct PriceChart: View {
    let points: [PricePoint]
    let isLoading: Bool
    let tint: Color
    /// The app's language: a chart draws its axis labels once, so they are formatted in it explicitly, and a change of
    /// language draws them again (a page open during the change kept French dates in Chinese).
    @Environment(\.locale) private var locale

    /// The plotted range with a little headroom. An area mark anchors at zero by default, which flattens a
    /// 24-hour price line into a ruler, so the fill starts at this floor instead.
    private var domain: ClosedRange<Double> {
        let values = points.map(\.usd)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.08, abs(high) * 0.0005, 1e-12)
        return (low - padding)...(high + padding)
    }

    /// The time axis's labels: hours for a day's line (Home's token page), days for a longer one (a launch page charts a
    /// coin since its launch). A mark every 6 hours over weeks drew a hundred grid lines and labels piled into one strip.
    private var timeFormat: Date.FormatStyle {
        guard let first = points.first?.time, let last = points.last?.time, last.timeIntervalSince(first) > 36 * 3600 else {
            return Date.FormatStyle.dateTime.hour().locale(locale)
        }
        return Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
    }

    var body: some View {
        if points.count >= 2 {
            Chart(points) { point in
                LineMark(x: .value("Time", point.time), y: .value("Price", point.usd))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                AreaMark(x: .value("Time", point.time), yStart: .value("Floor", domain.lowerBound), yEnd: .value("Price", point.usd))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
            }
            .chartYScale(domain: domain)
            // Centred on their marks: a date label starts at its mark by default, so the last one ran past the plot ("Oc…").
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: timeFormat, centered: true) } }
            .chartYAxis {
                // Labels as fine as the plotted range needs (`PriceFormat.axis`), so a dust coin's ticks don't all read "0".
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel { if let price = value.as(Double.self) { Text(PriceFormat.axis(price, span: domain.upperBound - domain.lowerBound)) } }
                }
            }
            .accessibilityLabel("Price over the past 24 hours")
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Price History", systemImage: "chart.line.downtrend.xyaxis")
            } description: {
                Paragraph("This token has no pool with enough liquidity to chart.")
            }
        }
    }
}


/// The home header, in the reference layout: the three-line menu button, a search field, and the profile avatar
/// on the right — the profile is one tap away from the top of the screen instead of a tab.
struct HomeHeader: View {
    @Binding var showSearch: Bool
    let error: String?
    let updatedAt: Date?
    @Environment(Router.self) private var router
    @Environment(Session.self) private var session
    @Environment(SocialSession.self) private var social

    var body: some View {
        HStack(spacing: 10) {
            Button { Haptics.tap(); router.menuOpen = true } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
            }
            .accessibilityLabel("Menu")

            Button { Haptics.tap(); showSearch = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search tokens…").foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if let error {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.attention).accessibilityLabel(error)
                    } else if let updatedAt {
                        Text(updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .font(.body)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search tokens")

            Button { Haptics.tap(); router.presented = .notifications } label: {
                Image(systemName: NotificationHub.shared.unreadCount > 0 ? "bell.badge" : "bell")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.brand, Color.primary)
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        let unread = NotificationHub.shared.unreadCount
                        if unread > 0 {
                            Text(verbatim: unread > 99 ? "99+" : "\(unread)")
                                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.negative, in: Capsule())
                                .offset(x: 4, y: -2)
                        }
                    }
            }
            .accessibilityLabel("Notifications, \(NotificationHub.shared.unreadCount) unread")

            Button { Haptics.tap(); router.presented = .profile } label: {
                if let account = session.account, account.method == .watchOnly {
                    ZStack {
                        Circle().fill(Color(.secondarySystemGroupedBackground)).frame(width: 44, height: 44)
                        Image(systemName: "eye").foregroundStyle(.secondary)
                    }
                } else {
                    Avatar(url: avatarURL, initials: initials, size: 44)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }

    private var avatarURL: URL? {
        guard let raw = social.profile?.avatar_url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var initials: String {
        let source = social.profile?.display_name ?? social.profile?.handle ?? session.account?.label ?? ""
        let letters = source.split(whereSeparator: { $0 == " " || $0 == "@" }).prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "" : String(letters).uppercased()
    }
}

/// A Moments stake row for the holdings list: media, name, editions and coins, then the value at the price Home counts
/// it at (`HomeTotals`); a Moment still collecting says "Not trading yet" in its place.
private struct MomentHoldingRow: View {
    let row: MomentPortfolioRow
    let value: Double?

    private var coins: Double { HomeModel.coins(row) }

    var body: some View {
        HStack(spacing: 12) {
            MomentArtwork(provenance: row.moment.provenance, symbol: row.moment.symbol, creator: row.moment.moment.creator)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.moment.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(verbatim: "\(tr("\(row.nftBalance) editions")) · \(NumberStyle.number(coins, compact: true)) \(row.moment.symbol)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if row.moment.isNotTradingYet {
                    Text("Not trading yet").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                } else {
                    USDText(value: value, font: .subheadline.weight(.medium))
                }
                Text(row.moment.graduated ? "Graduated" : row.moment.state == .expired ? "Expired" : "\(row.moment.progressBps / 100)% to graduation")
                    .font(.caption2).foregroundStyle(row.moment.graduated ? Color.positive : .secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
