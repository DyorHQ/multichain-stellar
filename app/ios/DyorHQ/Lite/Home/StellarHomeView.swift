// Stellar copy of ios/DyorHQ/Home/HomeView.swift heroCard (42cd8c7 sha256:df9731aebd6e)
// Stellar copy of ios/DyorHQ/Home/HomeView.swift totalVolume (42cd8c7 sha256:420cacff50f8)
// Stellar copy of ios/DyorHQ/Home/HomeView.swift topTokensCard (42cd8c7 sha256:43e06b054c1b)
// Stellar copy of ios/DyorHQ/Home/HomeView.swift holdingsCard (42cd8c7 sha256:6cd6877dc887)
// Stellar Home (docs/DESIGN-stellar-parity.md §8.2; decisions 6 and 7). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// A token page in Home's stack: a registry asset's id ("XLM", "USDC") or a coin's contract.
struct StellarAssetPage: Hashable, Identifiable {
    let asset: String
    var id: String { asset }
}

/// Stellar's Home, laid out as Monad's: the add-funds card while the account needs funds, the balance card (the
/// network chip, the total and its 24h change, Total Volume, Avail. Balance and In Use, the four-part split), the four
/// actions, the allocation ring, Top Tokens and My Holdings. Every figure is a viewer or public read (`/v1/holdings`,
/// `/v1/account`, `/v1/markets`), so Home fills with or without a session; Total Volume is DyorHQ's history
/// (`/v1/portfolio`), which a passkey account whose session is gone signs in for, only when it taps to (decision 6).
///
/// Nothing locks: after a relaunch, an expired session or the background, Home shows what it saved for the account,
/// then the fresh figures, with no prompt. Paused (maintenance, an update needed, access turned off), the balance card
/// says why and offers Monad. A Stellar destination for Home's tab (a bridge's notification) opens over it.
struct StellarHomeView: View {
    @Environment(\.stellarSession) private var session
    @Environment(Session.self) private var account
    @Environment(Router.self) private var router
    @Environment(\.stellarActions) private var actions
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = StellarHomeModel()
    /// The add-funds card for an account short of funds (§8.2.3).
    @State private var funding = StellarFundingWatch()
    @State private var tokenTab: HomeTokenTab = .popular
    @State private var holdingTab: StellarHoldingCategory = .spot
    @State private var showReceive = false
    @State private var showBridge = false
    @State private var showSend = false
    @State private var showTransfer = false
    @State private var showSearch = false
    @State private var searchTarget: StellarAssetPage?
    /// The Top Tokens rank column: 16 pt at the default text size, grown with the rank's footnote text so a digit never
    /// shows as "…" at the accessibility sizes. The dividers are inset by it too (`StellarTokenListRow.textInset`).
    @ScaledMetric(relativeTo: .footnote) private var rankWidth: CGFloat = 16

    private var store: LiteStore? { session?.store }
    /// The account's figures can be read and its actions taken: set up on this iPhone and not paused.
    private var isReady: Bool { session?.home == .ready && store != nil }
    private var canSign: Bool { session?.canSign ?? false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if isReady, funding.phase.isVisible, let store, let address = StellarAccountID(store.address) {
                        addFundsCard(store: store, address: address)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                    heroCard
                    quickActions
                    if let split = model.split, split.total > 0 || model.hasHoldings { allocationCard(split) }
                    topTokensCard
                    holdingsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.snappy, value: funding.phase)
                // Nothing here is animated by a saved line (Monad Home's rule): saved figures never animate in.
            }
            .background(Color(.systemGroupedBackground))
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HomeHeader(showSearch: $showSearch, error: model.error(store: store, markets: session?.publicReads) ?? volumeError,
                           updatedAt: model.updatedAt)
            }
            .navigationDestination(for: StellarAssetPage.self) { page in StellarTokenDetailView(asset: page.asset) }
            .navigationDestination(item: $searchTarget) { page in StellarTokenDetailView(asset: page.asset) }
            // A pull awaits Home's own reads and Total Volume's, side by side, in a task of their own: SwiftUI cancels a
            // pull's action when the list redraws under it. A paused or idle session is looked at again first, without a
            // prompt.
            .refreshable {
                guard let session else { return }
                let period = router.period
                await Task {
                    async let home: Void = model.load(session, resume: true)
                    async let volume: Void = model.loadVolume(session.store, period: period)
                    _ = await (home, volume)
                }.value
            }
            // What was saved for the account is in Home's first frame, never placeholders under figures the phone has:
            // a small file on the device, read here, before that frame. Never animated: nothing moves as it comes in.
            .onAppear {
                withTransaction(\.disablesAnimations, true) {
                    model.showSaved(owner: account.address, stellar: session?.address)
                    syncFromStore()
                }
            }
            .onChange(of: Owner(account: account.address, stellar: session?.address)) { _, owner in
                model.showSaved(owner: owner.account, stellar: owner.stellar)
                syncFromStore()
            }
            // The store's reads land here whoever asked for them: Home's own, the root's, and the read after any settled
            // action (`LiteStore.onSettled`).
            .onChange(of: store?.holdings) { _, _ in if let store { model.sync(from: store) } }
            .onChange(of: StellarHomeModel.parts.map { store?.status($0.lite) }) { _, _ in if let store { model.sync(from: store) } }
            .onChange(of: store?.portfolio) { _, _ in if let store { model.syncVolume(from: store) } }
            // Sign out of Stellar: the session's store goes, and its figures with it.
            .onChange(of: store.map(ObjectIdentifier.init)) { old, new in
                if new == nil, old != nil { model.forget() } else { syncFromStore() }
            }
            // Every 30 s while on screen and the app is active: Top Tokens with or without a session, the account's
            // figures once Home is ready (with or without a session).
            .task(id: Poll(active: scenePhase == .active, ready: isReady, address: session?.address)) {
                guard scenePhase == .active, let session else { return }
                await model.poll(session)
            }
            // Total Volume for the period; again once a session comes back (a passkey account's sign-in).
            .task(id: Volume(period: router.period, ready: isReady, access: session?.access)) {
                guard isReady else { return }
                await model.loadVolume(store, period: router.period)
            }
            // The add-funds card's watch: while Home is on screen, ready, and the app is active.
            .task(id: Poll(active: scenePhase == .active, ready: isReady, address: store?.address)) {
                guard isReady, scenePhase == .active, let store, let session else { return }
                await funding.watch(store: store, markets: session.publicReads, isTestnet: session.isTestnet)
            }
            .onChange(of: funding.phase.isArrival) { _, arrived in
                // Show the deposit in the balance straight away rather than at Home's next 30 s read.
                if arrived, let session { Task { await model.load(session) } }
            }
            .sensoryFeedback(.success, trigger: funding.phase.isArrival) { _, arrived in arrived }
            .overlay { if firstRead { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $showReceive) { StellarReceiveSheet() }
            .sheet(isPresented: $showBridge) { StellarBridgeView() }
            .sheet(isPresented: $showSend) { StellarSendSheet() }
            .sheet(isPresented: $showTransfer) { StellarTransferSheet(direction: .toEarn, market: nil) }
            .sheet(isPresented: $showSearch) {
                StellarSearchSheet(purpose: .browse) { asset in
                    showSearch = false
                    searchTarget = StellarAssetPage(asset: asset)
                }
            }
            .onChange(of: router.pendingStellar, initial: true) { _, pending in
                guard case .bridge = pending else { return }
                router.pendingStellar = nil
                showBridge = true
            }
        }
    }

    /// Whose figures Home shows.
    private struct Owner: Equatable {
        let account: Address?
        let stellar: String?
    }

    /// What the poll and the add-funds watch run for: they start again when any of it changes.
    private struct Poll: Equatable {
        let active: Bool
        let ready: Bool
        let address: String?
    }

    private struct Volume: Equatable {
        let period: VolumePeriod
        let ready: Bool
        let access: LiteSession.Access?
    }

    /// The store's last reads, taken in (a store kept across network switches has them already).
    private func syncFromStore() {
        guard let store else { return }
        model.sync(from: store)
        model.syncVolume(from: store)
    }

    /// A read of the account is under way: Home's own, or the first one of the session (the root's).
    private var reading: Bool { model.loading || (isReady && store?.status(.spot) == .unread) }

    /// Nothing to show yet, saved or read, while the first read runs: a large spinner over the screen.
    private var firstRead: Bool {
        !model.reads.hasFigures(.spot) && (session?.publicReads.markets.isEmpty ?? true) && (reading || session?.home == .loading)
    }

    // MARK: Add funds

    private func addFundsCard(store: LiteStore, address: StellarAccountID) -> some View {
        StellarAddFundsCard(phase: funding.phase, address: address, isTestnet: session?.isTestnet ?? true,
                            onBridge: { showBridge = true },
                            onShowQR: { showReceive = true },
                            onFriendbot: { try await store.faucet() },
                            onSwap: { sell, buy, starter in router.openStellarSwap(sell: sell, buy: buy, starter: starter) },
                            onClose: { funding.close(address: store.address) })
    }

    // MARK: Hero

    /// The balance card: the network chip, then the total on the left with its 24h move, and on the right the account's
    /// Total Volume across DyorHQ for the selected period, with the period switch right under it; Avail. Balance and In
    /// Use; the four-part split; on testnet, what its dollar values are. Paused, why, and the way back to Monad.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            NetworkChipRow(network: .stellar)
            if case .paused(let failure) = session?.home {
                paused(failure)
            } else {
                figures
            }
        }
        // 10 on top with the chip row, whose 44 pt row puts the capsule 16 from the card's edge.
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 16, trailing: 16))
        .cardBackground()
    }

    @ViewBuilder private var figures: some View {
        HStack(alignment: .top, spacing: 12) {
            // The total and the day's move in it wait for every part of the account (`StellarHomeModel.total`).
            let unread = model.total == nil
            VStack(alignment: .leading, spacing: 4) {
                Text(PriceFormat.usdValue(model.total ?? 0))
                    .font(.system(size: 40, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText(value: model.total ?? 0))
                    .unreadFigure(unread)
                HStack(spacing: 8) {
                    Text(PriceFormat.usdValue(model.changeAmount, signed: true))
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                        .foregroundStyle(unread ? Color.secondary : model.changeAmount < 0 ? Color.negative : Color.positive)
                    ChangeBadge(value: unread ? 0 : model.change24hPercent ?? 0)
                }
                .unreadFigure(unread)
                if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: reading) }
            }
            Spacer(minLength: 8)
            totalVolume
        }
        // DyorHQ's history with no session (a passkey account whose session is gone): Total Volume waits for a sign-in
        // the user asks for. Nothing prompts until the button is tapped.
        if needsSignIn { StellarSignInRow() }

        Divider()

        HStack(alignment: .top) {
            statColumn("Avail. Balance", value: model.availableBalance, tint: .primary)
            Spacer()
            statColumn("In Use", value: model.inUse, tint: (model.inUse ?? 0) > 0 ? .positive : .primary, alignment: .trailing)
        }

        Divider()

        HStack(spacing: 10) {
            splitStat(.spot, model.spotValue, .allocationSpot)
            splitStat(.earn, model.earnValue, .allocationPerps)
            splitStat(.launch, model.launchValue, .allocationLaunchpad)
            splitStat(.moments, model.momentsValue, .allocationMoments)
        }

        if AppNetwork.stellar.isTestnet {
            Paragraph(LocalizedStringResource("Dollar values use mainnet market prices. Testnet assets have no value.", table: "StellarHome", comment: "Stellar Home, under the balance card on Stellar's test network: the dollar figures value test XLM and USDC at the real (mainnet) market's prices, though test assets are worth nothing"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Paused for maintenance, an update needed or access turned off: why, and the way back to Monad, which always works.
    private func paused(_ failure: LiteSession.Failure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            InlineError(message: LiteErrorText.describe(failure))
            PrimaryButton(title: Text("Switch to \(AppNetwork.monad.name)", tableName: "StellarHome", comment: "Stellar Home's balance card while DyorHQ on Stellar is paused: goes back to the Monad network. %@ is the network's name (Monad), never translated")) {
                actions.switchToMonad()
            }
        }
    }

    /// DyorHQ's history can't be read without a sign-in the user asks for (a passkey account in the public view).
    private var needsSignIn: Bool { store?.status(.portfolio) == .needsSignIn }

    /// The period's Total Volume couldn't be read: the header's warning, so a figure short of some trades is never taken
    /// for the whole.
    private var volumeError: String? {
        store?.status(.portfolio) == .failed
            ? tr("Part of your history couldn't be read just now, so some figures may be missing. Pull to refresh.") : nil
    }

    /// Total Volume for the period, right-aligned, with the period menu (24h · 7 days · 30 days · All) under it: the same
    /// figure the Portfolio breaks down by section. Tapping the number opens the Portfolio. Until the period is read in
    /// this session, the figure saved when the account was last read, said to be; else a placeholder, never "$0.00"
    /// ahead of it. With no session to read it (`needsSignIn`), a placeholder.
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
                SavedLine(date: volumeSavedAt, reading: model.loading)
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

    private var volumeKey: VolumePeriodKey? { VolumePeriodKey(rawValue: router.period.rawValue) }

    /// The period's Total Volume read in this session (`LiteStore.portfolio`).
    private var liveVolume: Double? { volumeKey.flatMap { store?.portfolio[$0]?.totals.volume } }

    private var shownVolume: Double? {
        guard !needsSignIn else { return nil }
        return liveVolume ?? volumeKey.flatMap { model.savedVolumes[$0]?.usd }
    }

    /// When the saved Total Volume shown was read; nil while the figure is this session's, or a placeholder.
    private var volumeSavedAt: Date? {
        guard !needsSignIn, liveVolume == nil, let volumeKey else { return nil }
        return model.savedVolumes[volumeKey]?.readAt
    }

    /// `value` nil: the part it comes from isn't read for the account yet, so a placeholder (`unreadFigure`).
    private func statColumn(_ title: LocalizedStringKey, value: Double?, tint: Color, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(PriceFormat.usdValue(value ?? 0)).font(.headline).monospacedDigit().foregroundStyle(tint)
                .unreadFigure(value == nil)
        }
    }

    /// One of the four categories under the balance, named as My Holdings' switch names it. `value` nil: the category
    /// isn't read for the account yet (a failed read included), so a placeholder (`unreadFigure`).
    private func splitStat(_ category: StellarHoldingCategory, _ value: Double?, _ dot: Color) -> some View {
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
        .accessibilityElement(children: .combine)
    }

    // MARK: Quick actions

    /// Monad's four actions: Bridge once Home is ready; Deposit whenever the account's address is known; Withdraw and
    /// Transfer once Home is ready, for an account that can sign on this iPhone.
    private var quickActions: some View {
        HStack(spacing: 10) {
            StellarHomeAction(title: "Bridge", symbol: "point.3.connected.trianglepath.dotted") { showBridge = true }
                .disabled(!isReady)
            StellarHomeAction(title: "Deposit", symbol: "creditcard") { showReceive = true }
                .disabled(session?.address == nil)
            StellarHomeAction(title: "Withdraw", symbol: "arrow.up") { showSend = true }
                .disabled(!isReady || !canSign)
            StellarHomeAction(title: "Transfer", symbol: "arrow.left.arrow.right") { showTransfer = true }
                .disabled(!isReady || !canSign)
        }
    }

    // MARK: Allocation

    /// Drawn once every part is read for the account (`StellarHomeModel.split`), so no share is a part not read yet.
    private func allocationCard(_ split: StellarHomeModel.Split) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allocation").font(.headline)
            AllocationDonut(
                segments: [
                    .init(label: tr("Spot"), value: split.spot, color: .allocationSpot),
                    .init(label: MenuItem.earnTitle, value: split.earn, color: .allocationPerps),
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

    /// Stellar's markets (`/v1/markets`, public): shown with or without a session, as Monad's always are.
    private var topTokensCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Tokens").font(.headline)
            Picker("Filter", selection: $tokenTab) {
                ForEach(HomeTokenTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            let tokens = StellarHomeModel.topTokens(session?.publicReads.markets ?? [], tab: tokenTab)
            if tokens.isEmpty {
                if session?.publicReads.markets.isEmpty ?? true, session?.publicReads.marketsError != nil {
                    retryRow(LocalizedStringResource("Markets couldn't be loaded just now.", table: "StellarHome", comment: "Stellar Home, Top Tokens: Stellar's markets couldn't be read. A Retry button follows. Stellar is never translated"))
                } else {
                    Text("Loading markets…").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(tokens.prefix(6).enumerated()), id: \.element.id) { index, row in
                        NavigationLink(value: StellarAssetPage(asset: row.id)) { StellarTokenListRow(rank: index + 1, row: row, rankWidth: rankWidth) }
                            .buttonStyle(.plain)
                        if index < min(5, tokens.count - 1) { Divider().padding(.leading, StellarTokenListRow.textInset(rankWidth: rankWidth)) }
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
                ForEach(StellarHoldingCategory.allCases) { Text(verbatim: $0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            // A tab says it holds none only once its part of the account was read (`HomeReadState`): before, a loading
            // row, or that it couldn't be read, with Retry.
            switch holdingTab {
            case .spot:
                let rows = model.holdings
                if rows.isEmpty {
                    if model.reads.hasFigures(.spot) { holdingsEmpty("No spot balances", "Buy or swap a token and it appears here.") }
                    else { holdingsUnreadRow(.spot, reading: "Reading your balances…") }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            NavigationLink(value: StellarAssetPage(asset: row.id)) { StellarHoldingRow(row: row) }.buttonStyle(.plain)
                            if index < rows.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
                savedUnreadRow(.spot)
            case .earn:
                // The positions are never saved (only Earn's total is): "none" only once they were read in this session.
                if model.earn.isEmpty {
                    if model.reads.isRead(.perps) {
                        holdingsEmpty(LocalizedStringResource("No Earn positions", table: "StellarHome", comment: "Stellar Home, My Holdings' Earn tab when the account lends nothing"),
                                      LocalizedStringResource("Supply XLM or USDC on the Earn tab to start earning.", table: "StellarHome", comment: "Stellar Home, My Holdings' Earn tab when the account lends nothing: how to start. XLM and USDC are never translated"))
                    } else {
                        holdingsUnreadRow(.perps, reading: "Reading your positions…")
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.earn.enumerated()), id: \.element.id) { index, position in
                            Button { router.openStellar(.earn(market: position.id)) } label: { StellarEarnPositionRow(position: position) }
                                .buttonStyle(.plain)
                            if index < model.earn.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
            case .launch:
                if model.launch.isEmpty {
                    if model.reads.hasFigures(.launch) { holdingsEmpty("No launch holdings", "Buy or launch a coin on the Launch tab.") }
                    else { holdingsUnreadRow(.launch, reading: "Reading your balances…") }
                } else {
                    VStack(spacing: 0) {
                        // Every launch holding opens its own Launch page, on the Launch tab, as Monad's do.
                        ForEach(Array(model.launch.enumerated()), id: \.element.id) { index, coin in
                            Button { router.openStellar(.launch(token: coin.token)) } label: { StellarLaunchHoldingRow(coin: coin) }
                                .buttonStyle(.plain)
                            if index < model.launch.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                    // Read before, and the last read failed: the coins shown are the last ones read.
                    if store?.status(.launch) == .failed { holdingsRetryRow("Some launch coins couldn't be read just now — showing the last ones read.") }
                }
                if model.launch.isEmpty { savedUnreadRow(.launch) }
            case .moments:
                let rows = StellarHomeModel.momentHoldings(model.editions, board: store?.moments ?? [], now: Date())
                if rows.isEmpty {
                    if model.reads.hasFigures(.moments) {
                        holdingsEmpty("No Moments yet", LocalizedStringResource("Collect a Moment on the Moments tab and your editions appear here.", table: "StellarHome", comment: "Stellar Home, My Holdings' Moments tab when the account holds no edition: how to get one"))
                    } else {
                        holdingsUnreadRow(.moments, reading: "Reading your Moments…")
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            Button { router.openStellar(.moment(id: row.momentId)) } label: { StellarMomentHoldingRow(row: row) }
                                .buttonStyle(.plain)
                            if index < rows.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
                savedUnreadRow(.moments)
            }
        }
        .padding(16)
        .cardBackground()
    }

    /// A part showing what was saved when it was last read whose read now failed: its saved figures stay, said to be
    /// saved above the balance, and the tab says the read failed, with Retry.
    @ViewBuilder private func savedUnreadRow(_ part: HomeReadState.Part) -> some View {
        if model.reads.isSaved(part), model.reads.status(part) == .failed {
            holdingsRetryRow(StellarHomeModel.unreadMessage(part))
        }
    }

    private func holdingsEmpty(_ title: LocalizedStringResource, _ detail: LocalizedStringResource) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Paragraph(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    /// A tab whose part of the account isn't read yet (`HomeReadState`): a loading row while its first read runs, and once
    /// that failed, says so with Retry. Never "No … yet" for want of an answer.
    @ViewBuilder private func holdingsUnreadRow(_ part: HomeReadState.Part, reading: LocalizedStringResource) -> some View {
        if model.reads.status(part) == .failed {
            holdingsRetryRow(StellarHomeModel.unreadMessage(part))
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(reading).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    /// A read that failed, said with Retry; a spinner in its place while Home reads again (the Retry, or its poll).
    private func holdingsRetryRow(_ message: LocalizedStringResource) -> some View {
        retryRow(message)
    }

    private func retryRow(_ message: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline) {
            InlineError(message: message)
            Spacer(minLength: 8)
            if model.loading {
                ProgressView().controlSize(.small)
            } else {
                Button("Retry") { if let session { Task { await model.load(session, resume: true) } } }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 12)
    }
}
#endif
