// Stellar copy of ios/DyorHQ/Perps/PerpsView.swift PerpsView (42cd8c7 sha256:f23b413449ea)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift PerpTradeView.body (42cd8c7 sha256:912c3b7d6fc8)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift marketHeader (42cd8c7 sha256:6237e923b02a)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift viewModePill (42cd8c7 sha256:3e7f70e1dad5)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift PerpTradeView.chartSection (42cd8c7 sha256:92244d1ba334)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift tradeGrid (42cd8c7 sha256:ba439a05be84)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift fundingPanel (42cd8c7 sha256:010c518f3e05)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift orderTicket (42cd8c7 sha256:72ee2e57306e)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift summaryRow (42cd8c7 sha256:32e6ec1b57a1)
// Stellar copy of ios/DyorHQ/Swap/SwapView.swift percentRow (42cd8c7 sha256:d13e94bb004f)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift longShortButtons (42cd8c7 sha256:6aa7328a8611)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift sideButton (42cd8c7 sha256:d8fc8a940d34)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift bottomSection (42cd8c7 sha256:dece019578c3)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift segmentedTabs (42cd8c7 sha256:c91d4f1dd768)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift tabButton (42cd8c7 sha256:786222f12215)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift emptyRow (42cd8c7 sha256:9c72a75c83d5)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift PositionCard (42cd8c7 sha256:ef92d2b62ecb)
// The Earn side of Stellar's Earn tab: Blend lending as Monad's Perps screen (docs/DESIGN-stellar-parity.md §8.6.3).
// Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// Earn, under the Earn tab's Swap | Earn switch, as Monad's Perps under Trade's: a single screen for the market on show
/// (`StellarEarnMarketView`), whose header's chevron switches markets in place through Select Market. The market shown is
/// the one a Stellar destination named (`stellar:earn/<id>`), else the account's largest position, else the pool's USDC
/// market, else the first; once the account's positions are known it stays put until the user picks another. Blend's
/// markets and the account's positions are read again every 30 seconds while Earn is on screen and the app is active.
struct StellarEarnView: View {
    @Environment(\.stellarSession) private var session
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = StellarEarnModel()
    /// The market the user picked, or the default once the account's positions were known.
    @State private var selectedId: String?
    /// The market a Stellar destination named, until the markets are read.
    @State private var requested: String?

    private var store: LiteStore? { session?.store }

    /// What the poll runs for: the account's figures, while the app is active.
    private struct Polling: Equatable {
        let store: ObjectIdentifier?
        let active: Bool
    }

    private var polling: Polling {
        Polling(store: store.map(ObjectIdentifier.init), active: scenePhase == .active)
    }

    /// The market on screen: the one picked, else the default (`StellarEarnModel.defaultMarket`).
    private var currentMarket: EarnMarket? {
        guard let store else { return nil }
        let markets = store.earnMarkets
        if let selectedId, let picked = markets.first(where: { $0.id == selectedId }) { return picked }
        return StellarEarnModel.defaultMarket(markets, positions: store.holdings?.earn ?? [], requested: requested,
                                              assets: store.config?.assets ?? [])
    }

    /// Whether the default can be settled: the markets are read and so are the account's positions (or their read
    /// failed), so the largest position is known and the market won't jump once it is.
    private var defaultSettles: Bool {
        guard let store, !store.earnMarkets.isEmpty else { return false }
        return store.status(.earn) != .unread
    }

    var body: some View {
        NavigationStack {
            Group {
                if let store, let market = currentMarket {
                    StellarEarnMarketView(market: market, store: store, model: model) { id in
                        withAnimation(.easeInOut(duration: 0.15)) { selectedId = id }
                    }
                    .id(market.id) // reset the ticket cleanly when the market changes
                } else if store == nil || !model.marketsRead || model.loading {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("No Markets", systemImage: "chart.bar.xaxis")
                    } description: {
                        Paragraph(LocalizedStringResource("Blend's markets couldn't be loaded. Try again.", table: "StellarEarn", comment: "Stellar Earn with no market to show: Blend's lending markets couldn't be read. A Try Again button follows. Blend is a protocol's name, never translated"))
                    } actions: {
                        Button("Try Again") {
                            Haptics.tap()
                            guard let store else { return }
                            Task { await model.load(store: store) }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { StellarTradeModeSwitcher() }
            .task(id: polling) {
                guard polling.active, let store else { return }
                await model.poll(store: store)
            }
            // A market a notification or a link named opens over whatever was on screen, also when the tab is built for it.
            .onChange(of: router.pendingStellar, initial: true) { _, pending in
                guard case .earn(let id) = pending else { return }
                router.pendingStellar = nil
                requested = id
                selectedId = nil
            }
            .onChange(of: defaultSettles, initial: true) { _, settles in
                if settles, selectedId == nil, let market = currentMarket { selectedId = market.id }
            }
        }
    }
}

/// The words Earn shows in more than one place, each written once with its comment.
enum StellarEarnWords {
    static var supplyAPY: Text {
        Text("Supply APY", tableName: "StellarEarn", comment: "[tight] Stellar Earn: the yearly rate a market pays to those who lend to it (annual percentage yield), a label")
    }

    static var utilization: Text {
        Text("Utilization", tableName: "StellarEarn", comment: "[tight] Stellar Earn: how much of what was lent to a Blend market is borrowed out, a label")
    }

    static var supplied: Text {
        Text("Supplied", tableName: "StellarEarn", comment: "[tight] Stellar Earn: how much the account has lent to this market, a label")
    }

    static var earned: Text {
        Text("Earned", tableName: "StellarEarn", comment: "[tight] Stellar Earn: the interest the account's lending has earned so far, a label")
    }

    static var totalSupplied: Text {
        Text("Total supplied", tableName: "StellarEarn", comment: "[tight] Stellar Earn: a label. In the rates column, what everyone has lent to the market; on the Assets tab, what the account has lent across every market, in dollars")
    }

    /// "Utilization 62.30%": the market picker's line and the rates column's gauge.
    static func utilizationValue(_ percent: String) -> Text {
        Text("Utilization \(percent)", tableName: "StellarEarn", comment: "[tight] Stellar Earn: how much of a Blend market's lending is borrowed out. Under a market in the market picker, and VoiceOver's name for the rates column's gauge. The value is a percentage (62.30%)")
    }

    static var supplyToEarn: LocalizedStringResource {
        LocalizedStringResource("Supply to Earn", table: "StellarEarn", comment: "Stellar Earn: lend from the wallet (Spot) to a Blend market. A menu item, and the title of the deposit's review")
    }
}

/// One market of Stellar's Earn, as `PerpTradeView` lays out one perpetual: a tappable market header with its view-mode
/// pill and ⋯ menu; in order view the ticket beside the market's rates, with Deposit and Withdraw under it; in chart view
/// the market's supply APY over time; then the Position, Assets and History tabs. Deposit and Withdraw open the Stellar
/// review (`StellarConfirmationSheet`) on the amount as it stood at the tap. A rate is drawn in the neutral colour, never
/// as a gain; a testnet rate says it is one.
struct StellarEarnMarketView: View {
    let market: EarnMarket
    let store: LiteStore
    let model: StellarEarnModel
    /// Switches the market on screen in place (the host keeps the selection).
    var onSelectMarket: (String) -> Void = { _ in }

    /// The Monad account: a passkey account's quote would prompt with no session.
    @Environment(Session.self) private var account
    @Environment(\.stellarSession) private var stellar
    @Environment(\.stellarActions) private var actions
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewMode: ViewMode = .trade
    @State private var bottomTab: BottomTab = .position
    @State private var range: StellarRateRange = .week
    @State private var amountText = ""
    @State private var ticketError: LocalizedStringResource?
    /// The review on screen: the side and the amount as they stood when Deposit or Withdraw was tapped.
    @State private var review: Review?
    @State private var transfer: Transfer?
    @State private var showSelect = false
    @FocusState private var amountFocused: Bool

    // The raw values are identifiers; each tab's name on screen is its `title`.
    enum ViewMode: String, CaseIterable, Identifiable { case chart, trade; var id: String { rawValue } } // not localized: identifiers
    enum BottomTab: String, CaseIterable, Identifiable {
        case position, assets, history // not localized: identifiers
        var id: String { rawValue }
        var title: Text {
            switch self {
            case .position: Text("Position")
            case .assets: Text("Assets")
            case .history: Text("History")
            }
        }
    }

    /// A deposit or a withdrawal under review: its market and amount are fixed at the tap, so a poll that lands meanwhile
    /// can't change what the review shows and the plan does. `all`: a withdrawal of the whole position, `amount` (the
    /// supplied figure shown) the least it receives, with the interest earned until it goes through.
    struct Review: Identifiable {
        let id = UUID()
        let side: StellarEarnModel.Side
        let market: EarnMarket
        let amount: Int64
        var all = false
    }

    /// A transfer the ⋯ menu opened.
    struct Transfer: Identifiable {
        let id = UUID()
        let direction: StellarTransferDirection
    }

    // MARK: Figures

    private var assetInfo: AssetInfo? { store.asset(market.asset) }
    private var positions: [EarnPosition] { store.holdings?.earn ?? [] }
    private var position: EarnPosition? { StellarEarnModel.position(in: positions, for: market) }
    private var supplied: Int64 { position.map { StellarEarnModel.units($0.supplied) } ?? 0 }
    /// Whether the account's positions were read (the holdings' Earn part, at its last read): otherwise "Supplied" is
    /// unread, never 0, and the Position tab says why.
    private var positionsRead: Bool { store.status(.earn) == .read }
    private var status: StellarPoolStatus? { StellarPoolStatus(market.poolStatus) }
    private var takesDeposits: Bool { status?.takesDeposits ?? true }
    /// What a deposit can spend: for XLM, what keeps the network fee and the minimum balance back (§4.5).
    private var available: Int64 { store.maxAmount(asset: market.asset, stepKind: StellarEarnModel.depositStepKind) }
    /// Whether the account's balances were read: before, Available is unread, never 0.
    private var balancesRead: Bool { store.account != nil || store.holdings != nil }
    private var canSign: Bool { stellar?.canSign ?? false }
    private var typedAmount: Int64? { StellarEarnModel.amount(amountText, decimals: market.decimals) }
    private var apy: String { NumberStyle.percent(market.supplyApyPercent, signed: false) }
    private var isTestnet: Bool { AppNetwork.stellar.isTestnet }
    /// The wallet's asset beside the pool's own test version of it (Blend's test USDC on testnet).
    private var twin: (twin: AssetInfo, own: AssetInfo)? {
        StellarEarnModel.walletTwin(of: market, assets: store.config?.assets ?? [])
    }

    /// Whether a quote can be asked without a prompt: with a session, or for a seed account, which signs in silently.
    /// A passkey account with no session would see its passkey prompt just to view (decision 6), so it isn't asked.
    private var canQuote: Bool {
        canSign && (stellar?.access == .session || !account.isPasskeyAccount)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    marketHeader
                    if viewMode == .chart {
                        chartSection
                    } else {
                        ticketGrid.id(ScrollTarget.ticket)
                        actionButtons
                    }
                    notes
                    Divider().padding(.top, 2)
                    bottomSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: amountFocused) { _, focused in
                if focused { withAnimation { proxy.scrollTo(ScrollTarget.ticket, anchor: .top) } }
            }
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .keyboardDoneButton()
        .onChange(of: amountText) { _, _ in ticketError = nil }
        // The rate history, while the chart is on screen: again every 30 seconds, and at once for another range.
        .task(id: ChartRead(range: range, visible: viewMode == .chart && scenePhase == .active)) {
            guard viewMode == .chart, scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.loadHistory(store: store, market: market, range: range)
                try? await Task.sleep(for: StellarEarnModel.pollInterval)
            }
        }
        // Whether the wallet's USDC swaps into Blend's test USDC: asked until a quote says.
        .task(id: RouteCheck(canQuote: canQuote, asset: twin?.own.id)) {
            guard canQuote, let twin else { return }
            while !Task.isCancelled, model.routes[market.id] == nil {
                await model.checkRoute(store: store, market: market, from: twin.twin, to: twin.own)
                if model.routes[market.id] != nil { break }
                try? await Task.sleep(for: StellarEarnModel.pollInterval)
            }
        }
        // The History tab's deposits and withdrawals (DyorHQ's history), while the tab is on screen, and again once a
        // passkey account signs in for it: Earn's own read, which leaves the account's activity as other screens read it.
        .task(id: HistoryRead(visible: bottomTab == .history && scenePhase == .active, access: stellar?.access)) {
            guard bottomTab == .history, scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.loadActivity(store: store, market: market)
                try? await Task.sleep(for: StellarEarnModel.pollInterval)
            }
        }
        .sheet(item: $review) { review in reviewSheet(review) }
        .sheet(item: $transfer) { transfer in StellarTransferSheet(direction: transfer.direction, market: market.id) }
        .sheet(isPresented: $showSelect) {
            StellarSelectMarketSheet(markets: store.earnMarkets, currentId: market.id, asset: { store.asset($0.asset) }) { id in
                onSelectMarket(id)
            }
        }
    }

    private enum ScrollTarget: Hashable { case ticket }

    private struct ChartRead: Equatable {
        let range: StellarRateRange
        let visible: Bool
    }

    private struct RouteCheck: Equatable {
        let canQuote: Bool
        let asset: String?
    }

    private struct HistoryRead: Equatable {
        let visible: Bool
        let access: LiteSession.Access?
    }

    // MARK: Market header

    private var marketHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    Haptics.selection(); showSelect = true
                } label: {
                    HStack(spacing: 10) {
                        StellarTokenLogo(symbol: market.code, classic: assetInfo?.classic, size: 34)
                        HStack(spacing: 5) {
                            Text(verbatim: market.code).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(headerLabel)
                .accessibilityHint(Text("Changes the market.", tableName: "StellarEarn", comment: "VoiceOver hint on Stellar Earn's market header: tapping it opens the market picker"))

                Spacer(minLength: 8)

                viewModePill
                menu
            }
            headerRate
                .padding(.leading, 44)
        }
    }

    /// "%@ market, supply APY %@", and that the network is a test one.
    private var headerLabel: Text {
        isTestnet
            ? Text("\(market.code) market, supply APY \(apy), test network", tableName: "StellarEarn", comment: "VoiceOver: Stellar Earn's market header on the test network. The values are the asset's code (XLM) and the market's supply rate (4.21%)")
            : Text("\(market.code) market, supply APY \(apy)", tableName: "StellarEarn", comment: "VoiceOver: Stellar Earn's market header. The values are the asset's code (XLM) and the market's supply rate (4.21%)")
    }

    /// "Supply APY 4.21% [Testnet]", in the neutral colour (a rate isn't a gain), and the pool's status: on one line, else
    /// the status under the rate, else (the largest text sizes) each on its own line, the rate wrapping.
    private var headerRate: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                rateLine(wraps: false)
                Spacer(minLength: 8)
                if let status { StellarPoolStatusChip(status: status) }
            }
            VStack(alignment: .leading, spacing: 4) {
                rateLine(wraps: false)
                if let status { StellarPoolStatusChip(status: status) }
            }
            VStack(alignment: .leading, spacing: 4) {
                rateLine(wraps: true)
                if let status { StellarPoolStatusChip(status: status) }
            }
        }
    }

    @ViewBuilder private func rateLine(wraps: Bool) -> some View {
        let rate = Text("Supply APY \(apy)", tableName: "StellarEarn", comment: "[tight] Stellar Earn's market header, under the asset: the market's yearly rate for lenders. The value is a percentage (4.21%)")
            .font(.footnote.weight(.medium)).monospacedDigit()
            .foregroundStyle(.secondary)
        if wraps {
            VStack(alignment: .leading, spacing: 4) {
                rate.fixedSize(horizontal: false, vertical: true)
                if isTestnet { TestnetBadge() }
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 6) {
                rate.lineLimit(1).fixedSize()
                if isTestnet { TestnetBadge() }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var viewModePill: some View {
        HStack(spacing: 0) {
            ForEach(ViewMode.allCases) { mode in
                let active = viewMode == mode
                Button {
                    if viewMode != mode { Haptics.selection(); withAnimation(.easeInOut(duration: 0.15)) { viewMode = mode } }
                } label: {
                    Image(systemName: mode == .chart ? "chart.xyaxis.line" : "list.bullet.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 46, height: 38)
                        .foregroundStyle(active ? Color.brand : Color.secondary)
                        .background(active ? Color(.systemBackground) : .clear, in: Capsule())
                        .shadow(color: active ? .black.opacity(0.08) : .clear, radius: 3, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode == .chart ? "Chart view" : "Order view")
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Color(.tertiarySystemFill), in: Capsule())
        // The glyphs sit in fixed frames: past the largest standard size they would spill out of them.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var menu: some View {
        Menu {
            Button {
                transfer = Transfer(direction: .toEarn)
            } label: {
                Label { Text(StellarEarnWords.supplyToEarn) } icon: { Image(systemName: "plus.circle") }
            }
            .disabled(!takesDeposits)
            Button("Withdraw to Spot", systemImage: "minus.circle") { transfer = Transfer(direction: .toSpot) }.disabled(position == nil)
            Button("Portfolio", systemImage: "chart.xyaxis.line") { router.openStellar(.portfolio) }
            Divider()
            Label {
                Text("Rates from Blend", tableName: "StellarEarn", comment: "Stellar Earn's ⋯ menu, a line that isn't a button: the rates shown come from Blend, the Stellar lending protocol. Blend is never translated")
            } icon: {
                Image(systemName: "building.columns")
            }
        } label: {
            Image(systemName: "ellipsis").font(.headline).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // the glyph's circle is fixed, as the view-mode pill's frames
        }
        .accessibilityLabel("More options")
    }

    // MARK: Chart view

    private var chartSection: some View {
        StellarRateChart(points: model.points(market: market, range: range), range: $range,
                         isLoading: model.historyLoading, failed: model.historyFailed(market: market, range: range))
    }

    // MARK: Ticket beside the rates

    /// The ticket beside the 150 pt rates column, as Perps' ticket beside its book; at accessibility sizes, or where even
    /// the narrowest ticket can't sit beside it, the rates stack above the ticket, which then has the whole width.
    @ViewBuilder private var ticketGrid: some View {
        if Self.stacksRates(dynamicTypeSize) {
            stackedGrid
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ticket
                        .frame(minWidth: Self.ticketMinWidth, idealWidth: Self.ticketMinWidth, maxWidth: .infinity, alignment: .leading)
                    ratesColumn(stacked: false)
                        .frame(width: 150)
                }
                stackedGrid
            }
        }
    }

    /// The narrowest the ticket gets beside the rates column.
    private static let ticketMinWidth: CGFloat = 170

    /// Whether the rates stack above the ticket at `size`: at every accessibility size (AX1 to AX5), where a 150 pt column
    /// beside the ticket would clip both.
    static func stacksRates(_ size: DynamicTypeSize) -> Bool { size.isAccessibilitySize }

    private var stackedGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            ratesColumn(stacked: true)
            ticket
        }
    }

    /// Blend's figures for the market, as Perps' funding panel and book column: the two rates, the utilization with its
    /// gauge, what the pool holds and what can be withdrawn at once.
    private func ratesColumn(stacked: Bool) -> some View {
        let utilization = NumberStyle.percent(market.utilizationPercent, signed: false)
        return VStack(alignment: .leading, spacing: 10) {
            rate(StellarEarnWords.supplyAPY, Text(verbatim: apy), stacked: stacked)
            rate(Text("Borrow APY", tableName: "StellarEarn", comment: "[tight] Stellar Earn's rates column: the yearly rate borrowers pay this Blend market (annual percentage yield), a label"),
                 Text(verbatim: NumberStyle.percent(market.borrowApyPercent, signed: false)), stacked: stacked)
            VStack(alignment: .leading, spacing: 5) {
                rate(StellarEarnWords.utilization, Text(verbatim: utilization), stacked: stacked)
                Gauge(value: min(max(market.utilization, 0), 1)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(Color.brand)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(StellarEarnWords.utilizationValue(utilization))
            }
            rate(StellarEarnWords.totalSupplied, Text(verbatim: PriceFormat.usdValue(market.totalSuppliedUsd, compact: true)), stacked: stacked)
            rate(Text("Free to withdraw", tableName: "StellarEarn", comment: "[tight] Stellar Earn's rates column: what lenders could take out of this Blend market at once (lent less borrowed), in dollars, a label"),
                 Text(verbatim: PriceFormat.usdValue(market.freeLiquidityUsd, compact: true)), stacked: stacked)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rate(_ label: Text, _ value: Text, stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label.font(.caption2).foregroundStyle(.secondary)
            value.font(.caption.weight(.semibold)).monospacedDigit()
        }
        .lineLimit(stacked ? nil : 1)
        .minimumScaleFactor(stacked ? 1 : 0.8)
        .fixedSize(horizontal: false, vertical: stacked)
        .accessibilityElement(children: .combine)
    }

    private var ticket: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The pool the market lends through: static, as Perps' Isolated chip.
            HStack(spacing: 5) {
                Image(systemName: "building.columns").font(.caption2)
                Text(verbatim: StellarEarnModel.poolLabel(market.poolName)).font(.subheadline.weight(.semibold)) // not localized: Blend is a protocol's name, the pool's is its own
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Lends through Blend, pool \(StellarEarnModel.poolShortName(market.poolName))", tableName: "StellarEarn", comment: "VoiceOver: the chip on Stellar Earn's ticket naming the Blend pool the market lends through. The value is the pool's own name (TestnetV2). Blend is never translated"))

            // Available + add funds
            statRow(Text("Available"), balancesRead ? Text(verbatim: StellarFormat.amount(available, code: market.code, decimals: market.decimals)) : nil) {
                Button {
                    Haptics.selection(); actions.addFunds()
                } label: {
                    Image(systemName: "plus.circle").font(.subheadline)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.brand)
                .accessibilityLabel("Add funds")
            }

            StellarAmountField(title: "0" as String, text: $amountText, code: nil) {
                Haptics.selection(); amountText = StellarFormat.plain(units: available, decimals: market.decimals)
            }
            .focused($amountFocused)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            percentRow

            if let twin, model.routes[market.id] == true {
                Button {
                    Haptics.tap(); actions.openSwap(sell: twin.twin.id, buy: twin.own.id)
                } label: {
                    Label {
                        Text("Swap for Blend test \(market.code)", tableName: "StellarEarn", comment: "Stellar Earn's ticket on testnet, for the market of Blend's own test USDC: opens Swap to swap the wallet's USDC into it. The value is the asset's code (USDC). Blend is never translated")
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Color.brand)
                .frame(minHeight: 44)
            }

            // Summary
            VStack(spacing: 8) {
                summaryRow(StellarEarnWords.supplied, positionsRead ? Text(verbatim: StellarFormat.amount(supplied, code: market.code, decimals: market.decimals)) : nil)
                summaryRow(Text("Est. yearly interest", tableName: "StellarEarn", comment: "[tight] Stellar Earn's ticket: what the amount typed would earn in a year at today's supply rate, a label"), yearlyInterest)
                Text("At today's rate, which moves with demand.", tableName: "StellarEarn", comment: "Stellar Earn's ticket, under the estimated yearly interest: the estimate uses the current supply rate, which changes as borrowing changes")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)

            if let ticketError {
                Paragraph(ticketError).font(.caption).foregroundStyle(Color.attention)
            }
        }
    }

    /// What the amount typed would earn in a year at today's rate: in dollars when the asset has a price, else in the
    /// asset itself; nil (unread) with no amount.
    private var yearlyInterest: Text? {
        guard let amount = typedAmount, amount > 0 else { return nil }
        if let usd = StellarEarnModel.yearlyInterestUsd(amount: amount, market: market) { return Text(verbatim: PriceFormat.usdValue(usd)) }
        return Text(verbatim: StellarFormat.amount(StellarEarnModel.yearlyInterestUnits(amount: amount, market: market), code: market.code, decimals: market.decimals))
    }

    /// Quick-size the deposit to a share of what's available: 25 / 50 / 75 / 100%, the last one Max.
    private var percentRow: some View {
        HStack(spacing: 8) {
            ForEach([25, 50, 75, 100], id: \.self) { pct in
                Button {
                    Haptics.selection()
                    amountText = StellarFormat.plain(units: StellarEarnModel.share(pct, of: available), decimals: market.decimals)
                } label: {
                    Text(verbatim: "\(pct)%").lineLimit(1).minimumScaleFactor(0.6)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .disabled(available == 0)
    }

    /// A label and its figure on one line, as Perps' ticket rows: on two from the second accessibility size, where one
    /// can't hold both. A nil figure is unread, drawn as a placeholder and never as 0.
    private func statRow<Accessory: View>(_ label: Text, _ value: Text?, @ViewBuilder accessory: () -> Accessory) -> some View {
        let figure = (value ?? Text(verbatim: "0")).font(.subheadline.weight(.medium)).monospacedDigit().unreadFigure(value == nil)
        return Group {
            if dynamicTypeSize >= .accessibility2 {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        label.font(.subheadline).foregroundStyle(.secondary)
                        figure
                    }
                    Spacer(minLength: 6)
                    accessory()
                }
            } else {
                HStack {
                    label.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    figure.lineLimit(1).minimumScaleFactor(0.7)
                    accessory()
                }
            }
        }
    }

    private func summaryRow(_ label: Text, _ value: Text?, tint: Color? = nil) -> some View {
        Group {
            if dynamicTypeSize >= .accessibility2 {
                VStack(alignment: .leading, spacing: 2) {
                    label.font(.subheadline).foregroundStyle(.secondary)
                    (value ?? Text(verbatim: "—")).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(tint ?? .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    label.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    (value ?? Text(verbatim: "—")).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(tint ?? .primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Deposit / Withdraw

    private var actionButtons: some View {
        VStack(spacing: 10) {
            sideButton(.deposit, Text("Deposit"), fill: Color.positive, text: Color.onStatus, enabled: StellarEarnModel.canDeposit(market, canSign: canSign))
            sideButton(.withdraw, Text("Withdraw"), fill: Color(.tertiarySystemFill), text: Color.primary,
                       enabled: StellarEarnModel.canWithdraw(position, canSign: canSign))
            if !canSign {
                Text("Sign in to trade.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private func sideButton(_ side: StellarEarnModel.Side, _ label: Text, fill: Color, text: Color, enabled: Bool) -> some View {
        Button {
            attempt(side)
        } label: {
            label
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .foregroundStyle(enabled ? text : Color(.secondaryLabel))
                .background(fill.opacity(enabled ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func attempt(_ side: StellarEarnModel.Side) {
        if side == .deposit, !StellarEarnModel.canDeposit(market, canSign: canSign) { Haptics.warning(); return }
        if side == .withdraw, !StellarEarnModel.canWithdraw(position, canSign: canSign) { Haptics.warning(); return }
        if let problem = StellarEarnModel.problem(side, amount: typedAmount, available: available, supplied: supplied) {
            Haptics.warning(); ticketError = problem; return
        }
        guard let amount = typedAmount else { return }
        ticketError = nil
        amountFocused = false
        Haptics.commit()
        // The whole position typed: everything, with the interest earned since it was read, so no dust stays behind.
        review = Review(side: side, market: market, amount: amount, all: StellarEarnModel.takesEverything(side, amount: amount, supplied: supplied))
    }

    /// The whole position back to the wallet, from the Position tab: its review at once. It asks for everything, with the
    /// interest earned until it goes through, so nothing stays behind in the pool.
    private func withdrawAll() {
        guard canSign, supplied > 0 else { return }
        Haptics.commit()
        review = Review(side: .withdraw, market: market, amount: supplied, all: true)
    }

    private func reviewSheet(_ review: Review) -> some View {
        let deposit = review.side == .deposit
        let market = review.market
        return StellarConfirmationSheet(
            title: deposit ? StellarEarnWords.supplyToEarn : LocalizedStringResource("Withdraw to Spot"),
            confirmTitle: deposit ? LocalizedStringResource("Deposit") : LocalizedStringResource("Withdraw"),
            build: { try await store.earnPlan(deposit: deposit, market: market, amount: review.amount, all: review.all) },
            onDone: {
                amountText = ""
                Task { await model.load(store: store) }
            },
            // The History tab's rows again, once it has been read: Earn's own read, never the account's activity.
            onCompleted: { _ in
                guard model.marketActivity?.market == market.id else { return }
                Task { await model.loadActivity(store: store, market: market) }
            }
        ) {
            DetailRow("Amount", verbatim: StellarFormat.amount(review.amount, code: market.code, decimals: market.decimals))
            if review.all {
                Text("Your whole position, with what it earns until the withdrawal goes through.", tableName: "StellarEarn", comment: "Stellar Earn's withdrawal review, under the amount, when the whole position is withdrawn: the amount shown is the least that arrives, and the interest earned in the meantime comes too")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DetailRow(deposit ? "To" : "From", verbatim: StellarEarnModel.poolLabel(market.poolName))
            DetailRow(StellarEarnWords.supplyAPY, Text(verbatim: NumberStyle.percent(market.supplyApyPercent, signed: false)))
        }
    }

    // MARK: Notes

    /// Under the ticket or the chart: on testnet, that Blend's pool lends its own test USDC, and that testnet rates come
    /// from test activity.
    @ViewBuilder private var notes: some View {
        if isTestnet {
            VStack(alignment: .leading, spacing: 6) {
                if twin != nil {
                    Paragraph(LocalizedStringResource("On testnet, Blend's pool uses its own test \(market.code), not the \(market.code) in your wallet.", table: "StellarEarn", comment: "Stellar Earn, under the market of Blend's own test USDC on the test network: it isn't the USDC the wallet holds. Both values are the asset's code (USDC). Blend is never translated"))
                }
                Paragraph(LocalizedStringResource("Testnet rates come from test activity, not real markets.", table: "StellarEarn", comment: "Stellar Earn on the test network, a footnote: the rates shown are set by testers' lending and borrowing, not by a real market"))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Bottom section (position / assets / history)

    private var bottomSection: some View {
        VStack(spacing: 14) {
            segmentedTabs
            switch bottomTab {
            case .position:
                switch store.status(.earn) {
                case .read:
                    if let position {
                        StellarEarnPositionCard(position: position, market: market, classic: assetInfo?.classic, canSign: canSign,
                                                canDeposit: takesDeposits, onSupplyMore: supplyMore, onWithdraw: withdrawAll)
                    } else {
                        emptyRow(Text("No position in this market", tableName: "StellarEarn", comment: "Stellar Earn's Position tab when the account has lent nothing to this market"))
                    }
                case .failed:
                    InlineError(message: StellarEarnView.unreadPositions)
                case .unread, .needsSignIn:
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            case .assets:
                assetsList
            case .history:
                historyList
            }
        }
    }

    /// Supply More: back to the ticket, its field focused.
    private func supplyMore() {
        withAnimation(.easeInOut(duration: 0.15)) { viewMode = .trade }
        amountFocused = true
    }

    /// Position / Assets / History as underline tabs: each title on one line at its own width, the selected one semibold
    /// without moving the others. When they don't all fit, the row scrolls sideways instead of wrapping.
    private var segmentedTabs: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(BottomTab.allCases) { tab in
                    tabButton(tab)
                    if tab != BottomTab.allCases.last { Spacer(minLength: 12) }
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) { ForEach(BottomTab.allCases) { tabButton($0).id($0) } }
                }
                .onAppear { proxy.scrollTo(bottomTab, anchor: .center) }
                .onChange(of: bottomTab) { _, tab in withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(tab, anchor: .center) } }
            }
        }
    }

    private func tabButton(_ tab: BottomTab) -> some View {
        let active = bottomTab == tab
        return Button {
            if bottomTab != tab { Haptics.selection(); withAnimation(.easeInOut(duration: 0.15)) { bottomTab = tab } }
        } label: {
            ZStack {
                tab.title.font(.subheadline.weight(.semibold)).hidden()   // the selected width, always reserved
                tab.title.font(.subheadline.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) { Capsule().fill(active ? Color.brand : .clear).frame(height: 2.5) }
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func emptyRow(_ text: Text) -> some View {
        text.font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    /// Every market together: what the account has lent and earned, the average rate, and what the wallet holds of the
    /// markets' assets.
    private var assetsList: some View {
        let totals = StellarEarnModel.totals(positions: positions, markets: store.earnMarkets, spot: store.holdings?.spot)
        let earnedTint: Color = (totals.earned ?? 0) < 0 ? .negative : (totals.earned ?? 0) > 0 ? .positive : .primary
        return DetailRows {
            assetRow(StellarEarnWords.totalSupplied, assetFigure(positionsRead ? PriceFormat.usdValue(totals.supplied) : nil))
            // What every position has earned so far, in dollars ("*": a position's earnings aren't known).
            assetRow(StellarEarnWords.earned, assetFigure(positionsRead ? StellarEarnModel.earnedText(totals) : nil), tint: totals.earned == nil ? .primary : earnedTint)
            assetRow(Text("Average APY", tableName: "StellarEarn", comment: "[tight] Stellar Earn's Assets tab: the supply rate across the account's positions, weighted by their values, a label"),
                     assetFigure(positionsRead ? totals.averageApy.map { NumberStyle.percent($0, signed: false) } ?? "—" : nil))
            assetRow(Text("Available in wallet", tableName: "StellarEarn", comment: "[tight] Stellar Earn's Assets tab: what the wallet (Spot) holds of the assets Earn lends, in dollars, a label"),
                     assetFigure(positionsRead ? PriceFormat.usdValue(totals.wallet) : nil))
        }
    }

    /// An Assets figure as it reads, or "—" where it can't be told yet (the positions not read, a value not priced): never
    /// $0.00 for something unknown.
    private func assetFigure(_ value: String?) -> Text {
        Text(verbatim: value ?? "—")
    }

    /// One Assets line: a `DetailRow`; at accessibility sizes the figure goes under its label, whole, where beside it the
    /// two would share one line and the figure would wrap mid-number.
    @ViewBuilder private func assetRow(_ label: Text, _ value: Text, tint: Color = .primary) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                label.foregroundStyle(.secondary)
                value.monospacedDigit().foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            DetailRow(label, value, tint: tint)
        }
    }

    /// This market's deposits and withdrawals, newest first, each opening its transaction on StellarExpert.
    @ViewBuilder private var historyList: some View {
        let read = model.activity(for: market)
        let items = read.items
        switch read.status {
        case .needsSignIn:
            StellarSignInRow()
        case .failed where items.isEmpty:
            HStack(alignment: .firstTextBaseline) {
                if let error = store.lastError { InlineError(message: error) } else { InlineError(message: StellarEarnView.unreadHistory) }
                Spacer(minLength: 8)
                Button("Retry") { Task { await model.loadActivity(store: store, market: market) } }.font(.footnote.weight(.semibold))
            }
        case .unread where items.isEmpty:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        default:
            if items.isEmpty {
                emptyRow(Text("No deposits or withdrawals in this market yet.", tableName: "StellarEarn", comment: "Stellar Earn's History tab when the account hasn't supplied to or withdrawn from this market"))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        StellarActivityRow(item: item).padding(.vertical, 8)
                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

extension StellarEarnView {
    /// The Position tab before the account's positions were ever read, when their read failed.
    static var unreadPositions: LocalizedStringResource {
        LocalizedStringResource("Your Earn positions couldn't be read just now.", table: "StellarEarn", comment: "Stellar Earn's Position tab when the account's positions couldn't be read: what it lends on Blend is unknown for now")
    }

    /// The History tab when the account's activity couldn't be read and the read gave no reason.
    static var unreadHistory: LocalizedStringResource {
        LocalizedStringResource("Your Earn history couldn't be read just now.", table: "StellarEarn", comment: "Stellar Earn's History tab when the account's deposits and withdrawals couldn't be read. A Retry button follows")
    }
}

/// A Blend pool's status on Earn's header: a dot and words in the status's colour, never the colour alone. Active pools
/// take deposits as usual; on ice, Blend paused borrowing; frozen, Blend paused deposits too.
struct StellarPoolStatusChip: View {
    let status: StellarPoolStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pool status: \(Text(label))", tableName: "StellarEarn", comment: "VoiceOver: the chip on Stellar Earn's market header with the Blend pool's status. The value is the status (Active, Borrowing paused, Deposits paused)"))
    }

    var tint: Color {
        switch status {
        case .active: .positive
        case .onIce: .attention
        case .frozen: .negative
        }
    }

    var label: LocalizedStringResource {
        switch status {
        case .active: LocalizedStringResource("Active", table: "StellarEarn", comment: "[tight] Stellar Earn's header: a Blend pool's status chip; the pool takes deposits and lends as usual (an adjective)")
        case .onIce: LocalizedStringResource("Borrowing paused", table: "StellarEarn", comment: "[tight] Stellar Earn's header: a Blend pool's status chip; the pool is on ice: Blend paused borrowing, deposits and withdrawals still work")
        case .frozen: LocalizedStringResource("Deposits paused", table: "StellarEarn", comment: "[tight] Stellar Earn's header: a Blend pool's status chip; the pool is frozen: Blend paused deposits and borrowing, withdrawals still work while it has free liquidity")
        }
    }
}

/// The account's position in a market, as Perps' `PositionCard`: the asset and its pool, what's supplied and worth, what
/// it has earned (signed and tinted; unread in the public view, where DyorHQ's record isn't shown, never 0) and the rate,
/// with Supply More and Withdraw (the whole position back to the wallet, with what it earns until then: nothing stays
/// behind).
struct StellarEarnPositionCard: View {
    let position: EarnPosition
    let market: EarnMarket
    /// The asset's classic form, for its logo.
    let classic: String?
    let canSign: Bool
    let canDeposit: Bool
    let onSupplyMore: () -> Void
    let onWithdraw: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var supplied: Int64 { StellarEarnModel.units(position.supplied) }
    private var earned: Int64? { StellarEarnModel.earned(position) }
    private var earnedUsd: Double? { StellarEarnModel.earnedUsd(position, market: market) }
    private var apy: Double? { position.supplyApyPercent ?? market.supplyApyPercent }

    /// "+0.42 XLM", "−0.01 XLM", or "0 XLM".
    static func signed(_ units: Int64, code: String, decimals: Int) -> String {
        let sign = units > 0 ? "+" : units < 0 ? "−" : ""
        return sign + StellarFormat.amount(units.magnitude > UInt64(Int64.max) ? Int64.max : Int64(units.magnitude), code: code, decimals: decimals)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StellarTokenLogo(symbol: market.code, classic: classic, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: market.code).font(.subheadline.weight(.semibold))
                    Text(verbatim: market.poolName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 8) {
                stat(StellarEarnWords.supplied, Text(verbatim: StellarFormat.amount(supplied, code: market.code, decimals: market.decimals)))
                stat(Text("Value"), Text(verbatim: PriceFormat.usdValue(position.valueUsd)))
                if let earned {
                    // What it has earned so far, in the asset and in dollars (at the market's price).
                    stat(StellarEarnWords.earned, Text(verbatim: Self.signed(earned, code: market.code, decimals: market.decimals)),
                         detail: earnedUsd.map { Text(verbatim: PriceFormat.usdValue($0, signed: true)) },
                         tint: earned < 0 ? .negative : earned > 0 ? .positive : .primary)
                } else {
                    stat(StellarEarnWords.earned, Text(verbatim: "—"), tint: .secondary)
                }
                stat(StellarEarnWords.supplyAPY, Text(verbatim: apy.map { NumberStyle.percent($0, signed: false) } ?? "—"))
            }
            .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var buttons: some View {
        Button(action: onSupplyMore) {
            Text("Supply More", tableName: "StellarEarn", comment: "[tight] A button on the account's Earn position: lend more to this market (goes back to the ticket)")
        }
        .buttonStyle(.bordered).controlSize(.small).tint(.brand)
        .disabled(!canSign || !canDeposit)
        Button("Withdraw", action: onWithdraw)
            .buttonStyle(.bordered).controlSize(.small).tint(.brand)
            .disabled(!canSign)
    }

    /// The card in words: "%@, %@ supplied, earned %@, %@ APY".
    private var spoken: Text {
        let amount = StellarFormat.amount(supplied, code: market.code, decimals: market.decimals)
        let rate = apy.map { NumberStyle.percent($0, signed: false) } ?? "—"
        if let earned {
            let units = Self.signed(earned, code: market.code, decimals: market.decimals)
            let gain = earnedUsd.map { "\(units) (\(PriceFormat.usdValue($0, signed: true)))" } ?? units
            return Text("\(market.code), \(amount) supplied, earned \(gain), \(rate) APY", tableName: "StellarEarn", comment: "VoiceOver: the account's position on Stellar Earn. The values are the asset's code (XLM), the amount lent with its code (100 XLM), the interest earned so far with its sign and code, and in dollars when priced (+0.42 XLM (+$0.08)), and the supply rate (4.21%)")
        }
        return Text("\(market.code), \(amount) supplied, \(rate) APY", tableName: "StellarEarn", comment: "VoiceOver: the account's position on Stellar Earn when what it earned isn't known. The values are the asset's code (XLM), the amount lent with its code (100 XLM) and the supply rate (4.21%)")
    }

    /// A labelled figure, with a second reading of it under it when there is one (what was earned, in dollars).
    private func stat(_ label: Text, _ value: Text, detail: Text? = nil, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            label.font(.caption2).foregroundStyle(.secondary)
            value.font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(tint)
            if let detail {
                detail.font(.caption2).monospacedDigit().foregroundStyle(tint)
            }
        }
    }
}
#endif
