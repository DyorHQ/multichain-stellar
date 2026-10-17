// Stellar copy of ios/DyorHQ/Portfolio/PortfolioView.swift PortfolioView (42cd8c7 sha256:6eec17634a12)
// Stellar copy of ios/DyorHQ/Portfolio/PortfolioView.swift PortfolioActivityRow (42cd8c7 sha256:d5d038e11aba)
// Stellar copy of ios/DyorHQ/Portfolio/AssetsModel.swift AssetsCard (42cd8c7 sha256:68c1adb13d95)
// Stellar's Portfolio (docs/DESIGN-stellar-parity.md §8.12.1; decision 6). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import Charts
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// The Portfolio for DyorHQ on Stellar, laid out as Monad's but with no Bridge, which Stellar doesn't have for now:
/// cumulative volume across Spot, Earn, Launch and Moments for the chosen period, then fees paid, P&L, fees received and
/// trade counts, in total and per section, with the network fees paid in XLM apart, the account's holdings and the
/// activity behind the numbers. Opened over the Stellar tabs from the side menu, Earn's menu, a Stellar notification or
/// Home's Total Volume, which share the period.
///
/// The figures are DyorHQ's history (`/v1/portfolio`): a passkey account whose session is gone sees them unread, with
/// "Sign in with your passkey" under the hero, and nothing prompts until it is tapped; the holdings fill in either way.
struct StellarPortfolioView: View {
    @Environment(\.stellarSession) private var session
    @Environment(Session.self) private var account
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model = StellarPortfolioModel()
    @State private var showAll = false

    private var store: LiteStore? { session?.store }
    private var key: VolumePeriodKey? { VolumePeriodKey(rawValue: router.period.rawValue) }
    /// How the history's last read went: `.needsSignIn` for a passkey account with no session.
    private var status: LiteReadStatus { store?.status(.portfolio) ?? .unread }
    /// The period's figures read in this session.
    private var live: StellarPortfolio? { key.flatMap { store?.portfolio[$0] } }

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if case .paused(let failure) = session?.home {
                        InlineError(message: LiteErrorText.describe(failure))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .cardBackground()
                    }
                    heroCard
                    breakdownCard
                    ForEach(StellarPortfolioModel.Section.allCases) { section in sectionCard(section) }
                    StellarAssetsCard(store: store, retiredCoins: model.retiredCoins, reading: model.loading) {
                        Task { await model.load(store, period: router.period, force: true) }
                    }
                    if status != .needsSignIn {
                        activityCard
                        if let note = live?.coverage.note {
                            Paragraph(verbatim: note).font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(tr("Portfolio"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); dismiss() } label: { Image(systemName: "xmark").fontWeight(.semibold) }
                        .accessibilityLabel(Text("Close"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Period", selection: $router.period) {
                            ForEach(VolumePeriod.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(router.period.label).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }
                    }
                    .accessibilityLabel("Period")
                }
            }
            // A pull awaits Portfolio's reads in a task of their own: SwiftUI cancels a pull's action when the screen redraws
            // under it.
            .refreshable {
                let period = router.period
                await Task { await model.load(store, period: period, force: true) }.value
            }
            // What was saved for the account is in the first frame, never placeholders under figures the phone has: a small
            // file on the device, read here, before that frame. Never animated.
            .onAppear {
                withTransaction(\.disablesAnimations, true) {
                    model.showSaved(owner: account.address, stellar: session?.address)
                    if let store { model.take(store.portfolio) }
                }
            }
            // The period's reads, once the account's store is there.
            .task(id: Load(period: router.period, store: store.map(ObjectIdentifier.init))) {
                await model.load(store, period: router.period, force: false)
            }
            // A passkey account signed in from the row: the history it waited for is read now. A session that comes back
            // silently while the reads run (a seed account's first read) restarts nothing: they go on with it.
            .onChange(of: session?.access) { _, access in
                guard access == .session, let store, StellarPortfolioModel.waitsForSignIn(store) else { return }
                let period = router.period
                Task { await model.load(store, period: period, force: false) }
            }
            // The store's reads land here whoever asked for them: this screen's, Home's Total Volume and the read after any
            // settled action.
            .onChange(of: store?.portfolio) { _, portfolios in if let portfolios { model.take(portfolios) } }
            // Sign out of Stellar: the session's store goes, and its figures with it.
            .onChange(of: store.map(ObjectIdentifier.init)) { old, new in if new == nil, old != nil { model.forget() } }
        }
    }

    /// What the reads run for: they start again when any of it changes.
    private struct Load: Equatable {
        let period: VolumePeriod
        let store: ObjectIdentifier?
    }

    // MARK: Hero

    /// The period's figures as shown: this session's once read, else those saved when the account was last read in full,
    /// said to be; else nil — placeholders, never $0.00.
    private var shown: StellarPortfolioModel.Shown? { key.flatMap { model.shown($0, live: live, status: status) } }
    private var totals: StellarPortfolioModel.Stats { shown?.figures.totals ?? StellarPortfolioModel.Stats() }
    /// No figure to show for the period yet.
    private var unread: Bool { shown == nil }

    /// `section`'s figures for the period as shown.
    private func shownStats(_ section: StellarPortfolioModel.Section) -> StellarPortfolioModel.Stats? {
        shown?.figures.stats(section)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Cumulative Volume").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(router.period.label).font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.brand.opacity(0.12), in: Capsule())
                }
                Text(PriceFormat.usdValue(totals.volume))
                    .font(.system(size: 38, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText(value: totals.volume))
                    .unreadFigure(unread)
                Paragraph(LocalizedStringResource("Across Spot, Earn, Launch and Moments", table: "StellarPortfolio", comment: "Stellar Portfolio, under the cumulative volume: the four sections it adds up, as the cards below name them"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // DyorHQ's history with no session (a passkey account whose session is gone): the figures wait for a sign-in
            // the user asks for. Nothing prompts until the button is tapped.
            if status == .needsSignIn { StellarSignInRow() }
            Divider()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metric("Fees paid", usd(totals.fees), tint: .primary)
                metric("P&L", signed(totals.pnl) + (totals.pnlComplete ? "" : "*"), tint: totals.pnl < 0 ? .negative : totals.pnl > 0 ? .positive : .primary)
                metric("Fees received", usd(totals.claimedFees), tint: totals.claimedFees > 0 ? .positive : .primary)
                metric("Trades", "\(totals.trades)", tint: .primary)
            }
            // The network's fees, paid in XLM as MON is on Monad: never part of Fees paid.
            Text("Network fees paid: \(StellarFormat.units(totals.networkFeesStroops)) XLM", tableName: "StellarPortfolio", comment: "Stellar Portfolio, under the figures: the Stellar network fees the account paid in the period, apart from DyorHQ's fees. %@ is an amount (0.0154); XLM is never translated")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .unreadFigure(unread)
            statusLine
            if AppNetwork.stellar.isTestnet {
                Paragraph(LocalizedStringResource("Dollar values use mainnet market prices. Testnet assets have no value.", table: "StellarPortfolio", comment: "Stellar Portfolio, in the hero card on Stellar's test network: the dollar figures value test XLM and USDC at the real (mainnet) market's prices, though test assets are worth nothing"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .cardBackground()
    }

    /// When the figures shown were read: saved ones say so, with why they stay when this read failed; this session's,
    /// how long ago, or that they are being read again.
    @ViewBuilder private var statusLine: some View {
        if let saved = shown?.savedAt {
            SavedLine(date: saved, reading: model.loading)
            if status == .failed, !model.loading { historyError }
        } else if model.loading, live != nil {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Refreshing…").font(.caption2).foregroundStyle(.tertiary) }
        } else if status == .failed {
            historyError
        } else if let live, status != .needsSignIn, let updated = StellarFormat.date(live.asOf) {
            Text("Updated \(updated, style: .relative) ago").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var historyError: some View {
        Label("Part of your history couldn't be read just now, so some figures may be missing. Pull to refresh.", systemImage: "exclamationmark.triangle")
            .font(.caption2).foregroundStyle(Color.attention)
    }

    /// A hero figure: a placeholder while the period has none to show (`unread`).
    private func metric(_ title: LocalizedStringKey, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
                .unreadFigure(unread)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Breakdown

    private struct Slice: Identifiable {
        let section: StellarPortfolioModel.Section
        let volume: Double
        var id: String { section.id }
    }

    private var slices: [Slice] { StellarPortfolioModel.Section.allCases.map { Slice(section: $0, volume: shownStats($0)?.volume ?? 0) } }

    private var breakdownCard: some View {
        let total = max(totals.volume, 0)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Volume by Section").font(.headline)
            if total > 0 {
                Chart(slices.filter { $0.volume > 0 }) { slice in
                    BarMark(x: .value("Volume", slice.volume))
                        .foregroundStyle(color(slice.section))
                        .cornerRadius(3)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 22)
                .accessibilityLabel("Share of volume per section")
            } else {
                Capsule().fill(Color(.tertiarySystemFill)).frame(height: 10)
            }
            VStack(spacing: 8) {
                ForEach(slices) { slice in
                    HStack(spacing: 8) {
                        Circle().fill(color(slice.section)).frame(width: 9, height: 9)
                        Text(verbatim: slice.section.title).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(PriceFormat.usdValue(slice.volume)).font(.subheadline.weight(.medium)).monospacedDigit()
                            .unreadFigure(unread)
                        Text(NumberStyle.percent(total > 0 ? slice.volume / total * 100 : 0, fractionDigits: 0, signed: false))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                            .unreadFigure(unread)
                    }
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    /// Monad's section colours, Earn in Perps'.
    private func color(_ section: StellarPortfolioModel.Section) -> Color {
        switch section {
        case .spot: return .allocationSpot
        case .earn: return .allocationPerps
        case .launch: return .allocationLaunchpad
        case .moments: return .allocationMoments
        }
    }

    // MARK: Sections

    /// A section's figures as shown (`shownStats`): placeholders while it has none, never $0.00. Earn's fourth figure is
    /// its trades, as Perps' is on Monad; the others', what they received.
    private func sectionCard(_ section: StellarPortfolioModel.Section) -> some View {
        let shown = shownStats(section)
        let stats = shown ?? StellarPortfolioModel.Stats()
        let unread = shown == nil
        return VStack(alignment: .leading, spacing: 12) {
            Button { open(section) } label: {
                HStack(spacing: 10) {
                    Image(systemName: section.symbol)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(color(section), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(verbatim: section.title).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    Text(PriceFormat.usdValue(stats.volume)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                        .unreadFigure(unread)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(section.title)")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                small("Volume", usd(stats.volume), unread: unread)
                small("Fees", usd(stats.fees), unread: unread)
                small("P&L", signed(stats.pnl) + (stats.pnlComplete ? "" : "*"), tint: stats.pnl < 0 ? .negative : stats.pnl > 0 ? .positive : .primary, unread: unread)
                small(section == .earn ? "Trades" : "Received", section == .earn ? "\(stats.trades)" : usd(stats.claimedFees), tint: section != .earn && stats.claimedFees > 0 ? .positive : .primary, unread: unread)
            }
            if section != .earn {
                Text("\(stats.trades) trades in the period").font(.caption2).foregroundStyle(.tertiary)
                    .unreadFigure(unread)
            } else {
                earnedSoFar
            }
        }
        .padding(16)
        .cardBackground()
    }

    /// What the account's Earn has earned so far, whatever the period: the all-time Earn P&L (Blend's value now, plus what
    /// was withdrawn, less what was deposited, for every market with a recorded deposit, open or withdrawn in full, at
    /// today's prices), as the P&L reads with All chosen. Saved figures until that period's read lands, a placeholder
    /// before; "—" while DyorHQ's history needs a sign-in (the public view has no record), "*" when a market's earnings
    /// aren't known.
    private var earnedSoFar: some View {
        let lifetime = model.shown(.all, live: store?.portfolio[.all], status: status)?.figures.stats(.earn)
        let earned = lifetime?.pnl
        return Text("Earned so far: \(lifetime.map(StellarEarnModel.earnedSoFarText) ?? "—")", tableName: "StellarEarn", comment: "Stellar Portfolio's Earn card, under its figures: what the account's Blend lending has earned so far, whatever the period, in dollars (+$0.42; a trailing * when a market's earnings aren't known)")
            .font(.caption2).monospacedDigit()
            .foregroundStyle(earned.map { $0 < 0 ? Color.negative : $0 > 0 ? Color.positive : Color.secondary } ?? Color.secondary)
            .unreadFigure(lifetime == nil && status != .needsSignIn)
    }

    private func small(_ title: LocalizedStringKey, _ value: String, tint: Color = .primary, unread: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
                .unreadFigure(unread)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Activity

    /// The period's activity as `/v1/portfolio` lists it, each row worded as Recent Activity words it when the account's
    /// activity holds its details (`StellarActivityPresenter`), else in the server's words. A past bridge's row is plain
    /// history, in grey: Stellar has no Bridge for now, so nothing here offers one.
    private var activityCard: some View {
        let rows = StellarPortfolioModel.rows(live)
        let shown = showAll ? rows : Array(rows.prefix(12))
        let details = Dictionary((store?.activity ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Text(verbatim: "\(rows.count)").font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Group {
                    if live != nil {
                        Text("Nothing in this period.")
                    } else if status == .failed, !model.loading {
                        Paragraph("Part of your history couldn't be read just now, so some figures may be missing. Pull to refresh.")
                    } else {
                        Text("Loading…")
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                        StellarPortfolioActivityRow(row: row, details: details[row.id], color: row.section.map(color) ?? .secondary)
                        if index < shown.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
                if rows.count > shown.count {
                    Button("Show all \(rows.count)") { showAll = true }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    /// A section's header: Portfolio closes, then the section opens on Stellar, on its tab or its side of the Earn tab.
    private func open(_ section: StellarPortfolioModel.Section) {
        Haptics.tap()
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            router.open(section.menuItem)
        }
    }

    private func usd(_ value: Double) -> String { PriceFormat.usdValue(value) }
    private func signed(_ value: Double) -> String {
        PriceFormat.usdValue(value, signed: true)
    }
}

/// One action of the period: its section's mark, its words, what it was worth and how long ago; it opens the transaction
/// on StellarExpert.
private struct StellarPortfolioActivityRow: View {
    let row: StellarPortfolioModel.Row
    /// The account's activity item with the same id, when read: what the row's words come from.
    let details: StellarActivityItem?
    let color: Color

    private var page: URL? { row.item.hash.flatMap { StellarExplorer.transaction($0, network: LiteGate.pinned.network) } }

    var body: some View {
        Group {
            if let page {
                Link(destination: page) { content }.foregroundStyle(.primary)
            } else {
                content
            }
        }
    }

    private var content: some View {
        let presentation = details.map(StellarActivityPresenter.present)
        return HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .font(.footnote.weight(.bold))
                .frame(width: 32, height: 32)
                .background(color.opacity(0.16), in: Circle())
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                (presentation.map { StellarActivityRow.title($0.title) } ?? Text(verbatim: row.item.title))
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                subtitle(presentation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let usd = row.item.usd { Text(PriceFormat.usdValue(usd)).font(.subheadline.weight(.medium)).monospacedDigit() }
                if let time = row.time { Text(time, style: .relative).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// The presenter's subtitle, else the server's, else the section's name, as Monad's rows fall back on theirs.
    private func subtitle(_ presentation: StellarActivityPresentation?) -> Text {
        if let subtitle = presentation?.subtitle { return StellarActivityRow.subtitle(subtitle) }
        if let subtitle = row.item.subtitle, !subtitle.isEmpty { return Text(verbatim: subtitle) }
        return Text(verbatim: row.sectionTitle)
    }
}

/// My Holdings on Stellar's Portfolio, as Monad's: one toggle between Assets (every token the account holds with a
/// balance, valued: its Spot assets and its launch coins) and NFTs (its Moment editions). A token opens Swap, a coin its
/// Launch page, and an edition its Moment. A coin or edition of the retired v1 contracts says "Retired". Filled from the
/// holdings (a viewer read), with or without a session.
private struct StellarAssetsCard: View {
    let store: LiteStore?
    /// The coins of the retired v1 launchpad (`StellarPortfolioModel.retiredCoins`).
    let retiredCoins: Set<String>
    /// Portfolio is reading: the holdings among its reads.
    let reading: Bool
    /// Reads the holdings again, after a read that failed in part.
    let retry: () -> Void
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var showAllTokens = false
    @State private var kind: Kind = .assets

    private enum Kind: String, CaseIterable, Identifiable {
        case assets, nfts
        var id: String { rawValue }
        var label: String {
            switch self {
            case .assets: return tr(LocalizedStringResource("Assets"))
            case .nfts: return tr(LocalizedStringResource("NFTs"))
            }
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var holdings: StellarHoldings? { store?.holdings }
    private var assets: [StellarPortfolioModel.Asset] { StellarPortfolioModel.assets(holdings) }
    private var editions: [StellarPortfolioModel.Edition] { StellarPortfolioModel.editions(holdings) }
    private var v1Moments: [String] { LiteGate.pinned.contracts("moments") }
    /// The holdings' first read is under way, or Portfolio's.
    private var loading: Bool { holdings == nil && (reading || store?.status(.spot) == .unread) }
    private func failed(_ part: LitePart) -> Bool { store?.status(part) == .failed || holdings?.parts[part.rawValue] == "failed" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("My Holdings").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
                else if kind == .assets, let value = StellarPortfolioModel.tokensValue(holdings), value > 0 {
                    Text(PriceFormat.usdValue(value)).font(.subheadline.weight(.semibold)).monospacedDigit()
                } else if kind == .nfts, !editions.isEmpty {
                    // A list that may be missing one counts at least what it shows, never passed off as all of them.
                    Text(verbatim: failed(.moments) ? "\(editions.count)+" : "\(editions.count)")
                        .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            Picker("Holdings", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            switch kind {
            case .assets: tokens
            case .nfts: nfts
            }
        }
        .padding(16)
        .cardBackground()
    }

    // MARK: Assets

    @ViewBuilder private var tokens: some View {
        let assets = self.assets
        if !loading, let gap = tokenGap(empty: assets.isEmpty) {
            // A read that failed in part is said, with Retry, never passed off as all the account holds.
            VStack(alignment: .leading, spacing: 8) {
                Paragraph(gap).font(.footnote).foregroundStyle(.secondary)
                Button("Retry", systemImage: "arrow.clockwise", action: retry).font(.footnote.weight(.medium))
            }
        }
        let unpriced = StellarPortfolioModel.unpricedCodes(assets)
        if !loading, StellarPortfolioModel.tokensValue(holdings) != nil, !unpriced.isEmpty {
            // A token nothing prices is no failure: the total is of the rest, and says what it leaves out.
            Paragraph("Doesn't include \(StellarPortfolioModel.codeList(unpriced)): no price found.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if assets.isEmpty, loading || tokenGap(empty: true) == nil {
            Text(loading ? "Reading the wallet…" : "No tokens in this wallet yet.").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
        }
        if !assets.isEmpty {
            let shown = showAllTokens ? assets : Array(assets.prefix(6))
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, asset in
                    switch asset {
                    case .spot(let row):
                        Button {
                            router.openStellarSwap(sell: row.id, buy: row.id == "USDC" ? "XLM" : "USDC")
                            dismiss()
                        } label: {
                            tokenRow(code: row.code, classic: row.classic, image: nil, badge: StellarTokenBadge.kind(badges: row.badges, verified: row.verified, code: row.code),
                                     note: Text(verbatim: row.name ?? row.code), balance: row.balance, decimals: row.decimals, value: row.valueUsd)
                        }
                        .buttonStyle(.plain)
                    case .coin(let coin):
                        // Every coin opens its own Launch page, as Home's do: its curve, its pool or its retired page.
                        Button {
                            router.openStellar(.launch(token: coin.token))
                            dismiss()
                        } label: {
                            tokenRow(code: coin.symbol, classic: nil, image: coin.image, badge: .launch,
                                     note: retiredCoins.contains(coin.token) ? retiredText : Text(verbatim: coin.name),
                                     balance: coin.balance, decimals: StellarFormat.decimals, value: coin.valueUsd)
                        }
                        .buttonStyle(.plain)
                    }
                    if index < shown.count - 1 { Divider().padding(.leading, 46) }
                }
            }
            if assets.count > shown.count {
                Button("Show all \(assets.count)") { showAllTokens = true }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
            }
        }
    }

    /// What part of the tokens couldn't be read, in words, as Monad's card says it: nil when all of them were.
    private func tokenGap(empty: Bool) -> LocalizedStringResource? {
        if holdings == nil {
            return store?.status(.spot) == .failed ? "Your balances couldn't be read. Check your connection and try again." : nil
        }
        guard failed(.spot) || failed(.launch) else { return nil }
        return empty ? "No tokens found, but part of your wallet couldn't be read, so some may be missing."
            : "Part of your wallet couldn't be read, so a token may be missing from the list and the total."
    }

    private var retiredText: Text {
        Text("Retired", tableName: "StellarPortfolio", comment: "[tight] Stellar Portfolio, My Holdings: a coin or Moment edition of DyorHQ's first (v1) Stellar contracts, which are retired: it can be viewed and sold or claimed, never bought or collected")
    }

    private func tokenRow(code: String, classic: String?, image: String?, badge: StellarTokenBadge.Kind?, note: Text,
                          balance: String, decimals: Int, value: Double?) -> some View {
        HStack(spacing: 12) {
            StellarTokenLogo.init(symbol: code, classic: classic, image: image, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: code).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if let badge { StellarTokenBadge(badge) }
                }
                note.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: StellarFormat.units(balance, decimals: decimals, compact: true)).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.primary)
                if let value { Text(PriceFormat.usdValue(value)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: NFTs

    @ViewBuilder private var nfts: some View {
        if !loading, holdings != nil, failed(.moments) {
            // A read that was a part is said, never "No NFTs".
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if editions.isEmpty {
                        Paragraph("No NFTs found, but part of your wallet couldn't be read, so some may be missing.")
                    } else {
                        Paragraph("Part of your wallet couldn't be read, so an NFT may be missing from the list.")
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
                Button("Retry", systemImage: "arrow.clockwise", action: retry).font(.footnote.weight(.medium))
            }
        } else if editions.isEmpty {
            Group {
                if holdings == nil, store?.status(.spot) == .failed {
                    Paragraph("Your balances couldn't be read. Check your connection and try again.")
                } else if holdings == nil {
                    Text("Reading the wallet…")
                } else {
                    Text("No NFTs in this wallet yet.")
                }
            }
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
        }
        if !editions.isEmpty {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(editions) { row in
                    Button { open(row.edition) } label: { editionTile(row.edition) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: tileLabel(row.edition)))
                }
            }
        }
    }

    private func editionTile(_ edition: StellarEdition) -> some View {
        let retired = StellarPortfolioModel.isRetired(edition, v1Moments: v1Moments)
        return VStack(alignment: .leading, spacing: 6) {
            Color(.tertiarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    StellarMomentArtwork(image: edition.posterUrl ?? (edition.mediaType == "video" ? nil : edition.mediaUrl),
                                         name: edition.title ?? "#\(edition.momentId)")
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            editionTitle(edition).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            HStack(spacing: 4) {
                if retired {
                    retiredText
                    Text(verbatim: "·")
                }
                Text(verbatim: "#\(edition.tokenId)")
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private func editionTitle(_ edition: StellarEdition) -> Text {
        if let title = edition.title { return Text(verbatim: title) }
        return Text("Moment #\(edition.momentId)", tableName: "StellarPortfolio", comment: "Stellar Portfolio, My Holdings' NFTs: a Moment edition whose Moment has no title, named by the Moment's number. %lld is the number")
    }

    /// A tile as VoiceOver reads it, as Monad's tiles are read: its name, then its caption ("Retired", the number).
    private func tileLabel(_ edition: StellarEdition) -> String {
        let name = edition.title ?? liteTr(LocalizedStringResource("Moment #\(edition.momentId)", table: "StellarPortfolio", comment: "Stellar Portfolio, My Holdings' NFTs: a Moment edition whose Moment has no title, named by the Moment's number. %lld is the number"))
        let retired = StellarPortfolioModel.isRetired(edition, v1Moments: v1Moments)
            ? liteTr(LocalizedStringResource("Retired", table: "StellarPortfolio", comment: "[tight] Stellar Portfolio, My Holdings: a coin or Moment edition of DyorHQ's first (v1) Stellar contracts, which are retired: it can be viewed and sold or claimed, never bought or collected"))
            : nil
        return ([name, retired, "#\(edition.tokenId)"] as [String?]).compactMap { $0 }.joined(separator: ", ")
    }

    /// Portfolio closes, then the Moment opens over the Moments tab: a v2 Moment by its NFT, a retired one by its number.
    private func open(_ edition: StellarEdition) {
        Haptics.tap()
        let destination = StellarPortfolioModel.destination(edition, v1Moments: v1Moments)
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            router.openStellar(destination)
        }
    }
}
#endif
