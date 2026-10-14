import BigInt
import DyorKit
import SwiftUI

/// The pro perpetuals screen, laid out like the best mobile perp DEXes: a tappable market header, a Chart/Trade view
/// toggle, and — in Trade view — the order ticket beside the live order book, with two full-width Long/Short buttons
/// under it. Placing an order, changing leverage, the order type, the size unit and the reference price each happen in
/// a focused bottom sheet with haptics, so the whole thing feels deliberate and fast. Everything — symbols, prices,
/// chart, book, positions — is Perpl's own data; orders go through the Exchange contract / Perpl trading connection.
struct PerpTradeView: View {
    let market: PerpMarket
    let model: PerpsModel
    /// Switch the visible market in place (the host owns the selection), so the header's chevron changes markets
    /// without a navigation push — the way a single-screen trading app does it.
    var onSelectMarket: (Int) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(Router.self) private var router

    @State private var feed = PerplFeed()
    @State private var candles: [PerpCandle] = []
    @State private var resolution = 3600
    @State private var loadingCandles = true
    /// The timeframe `candles` belong to: another timeframe's candles are never shown under this one's name (RS-10).
    @State private var candlesResolution: Int?
    /// The last candle read failed: the chart says so rather than "no history".
    @State private var candlesFailed = false
    /// The candles the chart draws: the selected timeframe's only, so a switch shows the spinner, not the old ones.
    private var shownCandles: [PerpCandle] { candlesResolution == resolution ? candles : [] }
    @State private var viewMode: ViewMode = .trade
    @State private var chartDataTab: ChartDataTab = .book
    @State private var bottomTab: BottomTab = .positions
    @State private var ticket = OrderTicket()
    @State private var sizePercent: Double = 0
    /// True for the one sizeText change the slider itself drives, so the amount .onChange doesn't recompute the
    /// percentage from the lot-rounded size and make the thumb fight the finger mid-drag.
    @State private var suppressPercentSync = false
    @State private var priceType: PriceType = .last
    @State private var ticketError: String?

    // Sheets
    @State private var showConfirm = false
    /// Which path the open order confirmation uses, fixed when Long/Short is tapped: non-nil is the one-click
    /// (keeper-forwarded) path for that Perpl account, nil the on-chain path. The socket's status changes in the
    /// background (keep-alive, reconnects, drops), and re-deciding inside the sheet would swap a sheet with an order in
    /// flight for a fresh one with an enabled button — a second order (security audit 2026-09-26).
    @State private var authedOrderAccount: Int?
    /// The order as it stood when Review was tapped: the review renders it and the plan signs it, so a mark that moves
    /// under an open review (a USD-sized order re-derives its size from the price) can't change one without the other.
    @State private var reviewInput: OrderInput?
    /// The side of the position the order under review closes, as the account held it when Review was tapped
    /// (`PerpCloseOrder.closes`): a reduce-only order, or one on the other side of the position, which Perpl nets against
    /// it. Noted once the order is sent, so its ending is not reported as a close from elsewhere.
    @State private var reviewCloses: PositionSide?
    /// The live outcome switch as it stood at the tap (`PerplTrading.liveOutcomes`), fixed with the path: an order keeps
    /// the mode of its tap.
    @State private var reviewLive = false
    /// This market's position at the tap and when it was read, and whether an order that can grow the same side rested
    /// here then: what the order's result is compared with if Perpl's own report never comes.
    @State private var reviewHeld: PerpPosition?
    @State private var reviewReadAt: Date?
    @State private var reviewRestingOnSide = false
    /// The wallet-signed order under review: its id from the moment it is signed (`onStarted`), which its result is
    /// followed under once its transaction confirms, and the desc id its plan signs (what finds it in the receipt).
    @State private var onChainOrder: UUID?
    @State private var planDescId: UInt64?
    @State private var showLeverage = false
    @State private var showOrderType = false
    @State private var showUnitPref = false
    @State private var showPriceType = false
    @State private var showSelect = false
    @State private var showDeposit = false
    @State private var showWithdraw = false
    @State private var showPortfolio = false
    @State private var closingPosition: PerpPosition?
    @State private var addingMargin: PerpPosition?
    @State private var cancellingOrder: PerpOrder?
    /// The path Close / Add Margin take, fixed at the tap that opens the sheet (p4 spec A.2): the account they go over the
    /// trading connection for, or nil for the wallet transaction. Never switched afterwards.
    @State private var closeRoute: PerplTrading.ActionAccount?
    @State private var marginRoute: PerplTrading.ActionAccount?
    /// The resting order a Cancel tap goes to Perpl's API for, fixed at the tap: the stream's order the chain's matches by
    /// its smart contract order id, the request it belonged to then, and the account — nil target: the wallet's cancel.
    @State private var cancelTarget: PerplOpenOrder?
    @State private var cancelTapRq: Int?
    @State private var cancelAccount: PerplTrading.ActionAccount?
    @State private var editingTriggers: PerpPosition?
    @State private var cancellingTriggers: TriggerCancelRequest?

    @State private var fills: [PerplFill] = []
    @State private var pnlByOrder: [Int: Double] = [:]
    @State private var loadingFills = false
    @State private var fillsError: String?

    // The raw values are identifiers; each tab's name on screen is its `title`.
    enum ViewMode: String, CaseIterable, Identifiable { case chart = "Chart", trade = "Trade"; var id: String { rawValue } } // not localized: identifiers
    enum ChartDataTab: String, CaseIterable, Identifiable {
        case book = "Order Book", trades = "Trades" // not localized: identifiers
        var id: String { rawValue }
        var title: Text {
            switch self {
            case .book: Text("Order Book", comment: "A tab under the chart: the market's bids and asks. [tight]")
            case .trades: Text("Trades", comment: "Trades: a tab under the Perps chart with the market's latest trades, and a count of trades on Portfolio [tight]")
            }
        }
    }
    enum BottomTab: String, CaseIterable, Identifiable {
        case positions = "Positions", orders = "Orders", assets = "Assets", history = "Trade History" // not localized: identifiers
        var id: String { rawValue }
        var title: Text {
            switch self {
            case .positions: Text("Positions", comment: "A tab of the Perps screen: the open positions. [tight]")
            case .orders: Text("Orders", comment: "A tab of the Perps screen: the open orders. [tight]")
            case .assets: Text("Assets", comment: "A tab: in My Holdings the tokens held, on Perps the trading account's balance [tight]")
            case .history: Text("Trade History", comment: "A tab of the Perps screen: this market's past trades. [tight]")
            }
        }
    }
    enum PriceType: String, CaseIterable, Identifiable {
        case last = "Last", mid = "Mid" // not localized: identifiers
        var id: String { rawValue }
        var title: Text {
            switch self {
            case .last: Text("Last", comment: "The price a limit order starts from: the last traded price. [tight]")
            case .mid: Text("Mid", comment: "The price a limit order starts from: the middle of the order book. [tight]")
            }
        }
    }

    private var position: PerpPosition? { model.positions.first { $0.perpId == market.id } }

    /// The account this screen acts for, at the tap.
    private var actionAccount: PerplTrading.ActionAccount? {
        guard session.canSign, let id = model.account?.accountId else { return nil }
        return .init(owner: session.address, accountId: id, passkey: session.isPasskeyAccount)
    }

    /// The API route for Close / Add Margin (nil: the wallet transaction, as before). Decided at the tap that opens the sheet.
    private var apiRoute: PerplTrading.ActionAccount? {
        guard let account = actionAccount else { return nil }
        return perplTrading.apiActionsLive(for: account) || perplTrading.apiActionsAfterUnlock(for: account) ? account : nil
    }
    private var live: PerplLiveState? { feed.state }
    private var mark: Double { live?.mark ?? market.mark }
    private var change24h: Double? { live?.change24h ?? model.change24h(for: market) }
    private var change24hAbs: Double? {
        if let prev = live?.prev24h, prev > 0 { return mark - prev }
        return change24h.map { mark * $0 / 100 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                marketHeader
                if viewMode == .chart {
                    chartSection
                } else {
                    tradeGrid
                    longShortButtons
                }
                Divider().padding(.top, 2)
                bottomSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .keyboardDoneButton()
        .task {
            ticket.leverage = min(settings.defaultLeverage, maxLeverage)
            ticket.slippageBps = settings.slippageBps
            feed.focus(market)
            await loadCandles()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await loadCandles(showSpinner: false)
            }
        }
        .onDisappear { feed.stop() }
        .onChange(of: resolution) { _, _ in Task { await loadCandles() } }
        .onChange(of: model.fillSignal) { _, _ in
            if model.lastFilledPerpId == market.id { withAnimation { bottomTab = .positions } }
        }
        .task(id: session.address) {
            perplTrading.refresh(account: session.account)
            // The user already connected Perpl trading in Profile; the single trading socket just idles to `.enrolled`
            // between visits. Bring it live up front (in the background, so it never blocks history) so `isReady` is
            // true and TP/SL is actually offered — instead of showing "Connect Perpl trading in Profile" to someone
            // who already did. ensureConnected() is a no-op when already live and respects backoff / a rejected key.
            Task { await perplTrading.ensureConnected() }
            await loadFills()
        }
        .onChange(of: ticket.tpslEnabled) { _, on in
            guard on else { return }
            // TP/SL and Reduce Only exclude each other (security audit GT-6): a reduce-only order's triggers would close
            // the side the account doesn't hold.
            ticket.reduceOnly = false
            Task { await perplTrading.ensureConnected() }
        }
        .onChange(of: ticket.reduceOnly) { _, on in if on { ticket.tpslEnabled = false } }
        .onChange(of: bottomTab) { _, tab in if tab == .history { Task { await loadFills() } } }
        .onChange(of: model.fillSignal) { _, _ in if model.lastFilledPerpId == market.id { Task { await loadFills() } } }
        .sheet(isPresented: $showConfirm, onDismiss: {
            reviewInput = nil; reviewCloses = nil
            // A wallet-signed order's sheet closed: its result shows on the status row from now on (or, never confirmed,
            // it expects no fill any more).
            if let id = onChainOrder { perplTrading.onChainSheetClosed(id) }
        }) { orderConfirmSheet }
        .sheet(isPresented: $showLeverage) {
            LeverageSheet(leverage: ticket.leverage, maxLeverage: maxLeverage) { chosen in
                ticket.leverage = chosen
                clampSizeToMargin()
            }
        }
        .sheet(isPresented: $showOrderType) {
            OrderTypeSheet(kind: ticket.kind) { kind in
                ticket.kind = kind
                if kind == .market {
                    // Post-Only / Reduce Only are Limit-only controls; clear them so a stale flag can't leak into a
                    // Market order (which would change its meaning and skip the margin guard in OrderTicket.problem).
                    ticket.reduceOnly = false
                    ticket.postOnly = false
                } else if ticket.priceText.isEmpty {
                    ticket.priceText = plainSize(referencePrice(priceType))
                }
            }
        }
        .sheet(isPresented: $showUnitPref) {
            UnitPreferenceSheet(unit: ticket.amountUnit, asset: market.asset) { unit in
                if unit != ticket.amountUnit { convertAmount(to: unit) }
            }
        }
        .sheet(isPresented: $showPriceType) {
            PriceTypeSheet(selected: priceType) { type in
                priceType = type
                ticket.priceText = plainSize(referencePrice(type))
            }
        }
        .sheet(isPresented: $showSelect) {
            SelectPerpetualSheet(markets: model.markets, currentId: market.id, change: { model.change24h(for: $0) }) { id in
                onSelectMarket(id)
            }
        }
        .sheet(isPresented: $showDeposit) { CollateralSheet(kind: .deposit, model: model) }
        .sheet(isPresented: $showWithdraw) { CollateralSheet(kind: .withdraw, model: model) }
        .sheet(isPresented: $showPortfolio) { PerpsPortfolioView(model: model) }
        .sheet(item: $closingPosition) { position in
            ClosePositionSheet(market: market, position: position, mark: mark, accountId: model.account?.accountId, leftoverTriggers: triggersProtecting(position),
                               route: closeRoute,
                               onSending: { whole in if whole { model.noteUserClose(market.id, closing: position.side) } }, onNotSent: { model.forgetUserClose(market.id) },
                               onSettled: { Task { await model.reloadSoon(env: env, address: session.address) } }) {
                Task { await model.load(env: env, address: session.address) }
            }
        }
        .sheet(item: $addingMargin) { position in
            AddMarginSheet(market: market, position: position, available: availableMargin, accountId: model.account?.accountId, route: marginRoute,
                           onSettled: { Task { await model.reloadSoon(env: env, address: session.address) } }) { Task { await model.load(env: env, address: session.address) } }
        }
        .sheet(item: $cancellingOrder) { order in
            // The path of the tap: Perpl's API for the stream order it matched, else the wallet's cancel as before.
            if let target = cancelTarget, let account = cancelAccount {
                CancelOrderSheet(market: market, order: order, target: target, tapRq: cancelTapRq, account: account) {
                    Task { await model.load(env: env, address: session.address) }
                }
            } else {
                cancelOrderSheet(order)
            }
        }
        .sheet(item: $editingTriggers) { position in
            PositionTriggersSheet(market: market, position: position, mark: mark) { Task { await model.load(env: env, address: session.address) } }
        }
        .sheet(item: $cancellingTriggers) { request in
            CancelTriggersSheet(market: market, orders: request.orders, title: request.title, note: request.note) { Task { await model.load(env: env, address: session.address) } }
        }
    }

    // MARK: Market header

    private var marketHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                Haptics.selection(); showSelect = true
            } label: {
                HStack(spacing: 10) {
                    MarketLogo(symbol: market.asset, url: nil, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(market.asset).font(.title3.weight(.bold))
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        headerChange
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            viewModePill
            Menu {
                Button("Deposit AUSD", systemImage: "plus.circle") { showDeposit = true }
                Button("Withdraw AUSD", systemImage: "minus.circle") { showWithdraw = true }.disabled(model.account == nil)
                Button("Portfolio", systemImage: "chart.xyaxis.line") { showPortfolio = true }.disabled(session.address == nil)
                Divider()
                Label(feed.connected ? "Live market data" : "Connecting…", systemImage: feed.connected ? "dot.radiowaves.left.and.right" : "hourglass")
            } label: {
                Image(systemName: "ellipsis").font(.headline).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color(.tertiarySystemFill), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options")
        }
    }

    @ViewBuilder private var headerChange: some View {
        let tint: Color = (change24h ?? 0) < 0 ? .negative : (change24h ?? 0) > 0 ? .positive : .secondary
        HStack(spacing: 6) {
            if let abs = change24hAbs {
                Text(PriceFormat.usdPrice(abs, signed: true))
            }
            if change24hAbs != nil, change24h != nil { Text(verbatim: "/") }
            if let pct = change24h { Text(NumberStyle.percent(pct)) }
        }
        .font(.footnote.weight(.medium)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.7) // one line: a signed dollar figure wrapped after its "−"
        .foregroundStyle(tint)
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
    }

    // MARK: Chart view

    private var chartSection: some View {
        VStack(spacing: 10) {
            TradingViewChart(candles: shownCandles, levels: chartLevels)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // The chart is a canvas in a web view: VoiceOver gets a spoken summary instead (security audit AI-10).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(market.asset) price chart")
                .accessibilityValue(chartSummary)
                .overlay(alignment: .topTrailing) { positionBadge }
                .overlay {
                    if shownCandles.isEmpty {
                        if loadingCandles { ProgressView() }
                        else if candlesFailed {
                            ContentUnavailableView { Label("Chart Unavailable", systemImage: "wifi.exclamationmark") } description: { Paragraph("Perpl's candles couldn't be loaded. Retrying every 15 seconds.") }
                        }
                        else {
                            ContentUnavailableView { Label("No Candles", systemImage: "chart.bar.xaxis") } description: { Paragraph("Perpl has no candle history for this market yet.") }
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if candlesFailed, !shownCandles.isEmpty {
                        Label("Not updating", systemImage: "wifi.exclamationmark")
                            .font(.caption2.weight(.medium)).foregroundStyle(Color.attention)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            timeframePicker
            Picker("Data", selection: $chartDataTab) {
                ForEach(ChartDataTab.allCases) { $0.title.tag($0) }
            }
            .pickerStyle(.segmented)
            switch chartDataTab {
            case .book:
                SideOrderBook(book: feed.book, mark: mark, mid: live?.mid ?? live?.last ?? mark, changePct: change24h, symbol: market.asset, priceDecimals: market.priceDecimals, rows: 9, wide: true)
                    .frame(minHeight: 260)
            case .trades:
                TradesTape(trades: feed.trades, symbol: market.asset).frame(minHeight: 260)
            }
        }
    }

    /// The chart in words, in the app's language: the period, the last price, the change over the period, and its range.
    /// The candle count is a plural.
    private var chartSummary: String {
        guard let first = shownCandles.first, let last = shownCandles.last else {
            return loadingCandles ? tr("Loading") : candlesFailed ? tr("Couldn't load the chart") : tr("No candle history yet")
        }
        let span = Self.resolutions.first { $0.0 == resolution }?.1 ?? ""
        let high = NumberStyle.number(shownCandles.map(\.high).max() ?? last.high)
        let low = NumberStyle.number(shownCandles.map(\.low).min() ?? last.low)
        let change = first.open > 0 ? (last.close - first.open) / first.open * 100 : 0
        let close = NumberStyle.number(last.close)
        let move = NumberStyle.percent(abs(change), signed: false)
        let count = shownCandles.count
        return change >= 0
            ? tr("\(count) \(span) candles. Last \(close), up \(move) over the period. High \(high), low \(low).")
            : tr("\(count) \(span) candles. Last \(close), down \(move) over the period. High \(high), low \(low).")
    }

    private var timeframePicker: some View {
        HStack(spacing: 8) {
            ForEach(Self.resolutions, id: \.0) { seconds, label in
                Button(label) { if resolution != seconds { Haptics.selection(); resolution = seconds } }
                    .font(.caption.weight(resolution == seconds ? .bold : .regular))
                    .foregroundStyle(resolution == seconds ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(resolution == seconds ? Color(.tertiarySystemFill) : .clear, in: Capsule())
            }
        }
    }

    /// The chart's timeframes in seconds, each with its label in the app's language (written as trading charts write them).
    static var resolutions: [(Int, String)] {
        [(60, tr(LocalizedStringResource("1m", comment: "Chart timeframe: one minute. [tight]"))),
         (300, tr(LocalizedStringResource("5m", comment: "Chart timeframe: five minutes. [tight]"))),
         (900, tr(LocalizedStringResource("15m", comment: "Chart timeframe: fifteen minutes. [tight]"))),
         (3600, tr(LocalizedStringResource("1h", comment: "Chart timeframe: one hour. [tight]"))),
         (14400, tr(LocalizedStringResource("4h", comment: "Chart timeframe: four hours. [tight]"))),
         (86400, tr(LocalizedStringResource("1D", comment: "Chart timeframe: one day. [tight]")))]
    }

    // MARK: Trade grid — order ticket beside the live book

    private var tradeGrid: some View {
        HStack(alignment: .top, spacing: 12) {
            orderTicket
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                fundingPanel
                SideOrderBook(book: feed.book, mark: mark, mid: live?.mid ?? live?.last ?? mark, changePct: change24h, symbol: market.asset, priceDecimals: market.priceDecimals, rows: 8, wide: false)
            }
            .frame(width: 150)
        }
    }

    private var fundingPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Funding (1h) / Countdown", comment: "Over the funding rate and the time to the next funding, in a narrow column. [tight]")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(fundingText).foregroundStyle(fundingTint)
                Text(verbatim: "/").foregroundStyle(.secondary)
                // A 1s timeline so the countdown ticks smoothly instead of only refreshing on incidental re-renders.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(countdownText(now: ctx.date)).foregroundStyle(.primary)
                }
            }
            .font(.caption.weight(.semibold)).monospacedDigit()
        }
    }

    // MARK: Order ticket (left column)

    private var orderTicket: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Margin mode (static — Perpl is isolated-only) · Leverage (tap to adjust)
            HStack(spacing: 8) {
                // A bordered, secondary chip rather than a filled capsule, so it doesn't mimic the tappable leverage
                // button beside it — Perpl only offers isolated margin, so there's nothing to toggle.
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.caption2)
                    Text("Isolated", comment: "Isolated margin: Perpl's only margin mode. [tight]").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Isolated margin")
                .accessibilityHint("This market is isolated-margin only")
                Button {
                    Haptics.selection(); showLeverage = true
                } label: {
                    Text(verbatim: "\(NumberStyle.number(ticket.leverage, maximumFractionDigits: ticket.leverage.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1))x")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                .accessibilityLabel("Leverage \(NumberStyle.number(ticket.leverage, maximumFractionDigits: 1)) times")
                .accessibilityHint("Adjust leverage")
            }

            // Available + add funds
            HStack {
                Text("Available").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(verbatim: "\(NumberStyle.number(availableMargin, maximumFractionDigits: 2)) AUSD")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Button {
                    Haptics.selection(); showDeposit = true
                } label: {
                    Image(systemName: "plus.circle").font(.subheadline)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.brand)
                .accessibilityLabel("Add funds")
            }

            // Order type (+ price-type for limit)
            HStack(spacing: 8) {
                Button { Haptics.selection(); showOrderType = true } label: {
                    HStack {
                        (ticket.kind == .market ? Text("Market", comment: "Order type: a market order, which fills at once at the market price. [tight]")
                                                : Text("Limit", comment: "Order type: rests at the price you set until it fills. [tight]")).fontWeight(.semibold)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                if ticket.kind == .limit {
                    Button { Haptics.selection(); showPriceType = true } label: {
                        priceType.title.font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(Color.brand.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.brand)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Price (limit) or Market Price placeholder
            if ticket.kind == .limit {
                stepperField(text: $ticket.priceText, placeholder: NumberStyle.number(mark), unit: "AUSD", step: priceStep)
            } else {
                Text("Market Price")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Amount + unit
            amountStepper

            // Size percent of available margin
            PercentSizeSlider(percent: $sizePercent) { pct in applyPercent(pct) }
                .disabled(model.account == nil || availableMargin <= 0)

            // Flags
            VStack(alignment: .leading, spacing: 10) {
                if ticket.kind == .market {
                    checkRow("Max Slippage", isOn: $ticket.maxSlippageEnabled)
                    if ticket.maxSlippageEnabled {
                        slippageField
                    }
                    checkRow("TP/SL", isOn: $ticket.tpslEnabled)
                } else {
                    checkRow("TP/SL", isOn: $ticket.tpslEnabled)
                    checkRow("Post-Only", isOn: $ticket.postOnly)
                    checkRow("Reduce Only", isOn: $ticket.reduceOnly)
                    if ticket.reduceOnly {
                        Paragraph("TP/SL can't go on a reduce-only order. Set it on the position instead.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if ticket.effectiveTPSL { tpslFields }

            // Summary
            VStack(spacing: 8) {
                // Named in words, not told apart by green and red alone (security audit AI-3): the side isn't chosen
                // until Long or Short is tapped, so both are shown.
                summaryRow("Liq. if long", liquidationLong.map { NumberStyle.number($0) } ?? liquidationFallback, tint: liquidationLong == nil ? nil : .positive)
                summaryRow("Liq. if short", liquidationShort.map { NumberStyle.number($0) } ?? liquidationFallback, tint: liquidationShort == nil ? nil : .negative)
                summaryRow("Max", "\(NumberStyle.number(maxNotional, maximumFractionDigits: 2)) AUSD")
                summaryRow("Fee", "\(NumberStyle.number(estFee, maximumFractionDigits: 2)) AUSD")
            }
            .padding(.top, 2)

            if let ticketError {
                Paragraph(ticketError).font(.caption).foregroundStyle(Color.attention)
            }
        }
    }

    private var amountStepper: some View {
        HStack(spacing: 4) {
            Button { adjustAmount(-amountStep) } label: {
                Image(systemName: "minus").font(.subheadline.weight(.semibold)).frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Decrease amount")
            TextField("Amount", text: $ticket.sizeText)
                .keyboardType(.decimalPad).multilineTextAlignment(.center).monospacedDigit()
                .font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                .onChange(of: ticket.sizeText) { _, _ in
                    ticketError = nil
                    // Keep the % slider in step with a typed amount, unless the slider itself drove this change.
                    if suppressPercentSync { suppressPercentSync = false } else { syncPercentFromSize() }
                }
            Button { adjustAmount(amountStep) } label: {
                Image(systemName: "plus").font(.subheadline.weight(.semibold)).frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Increase amount")
            Divider().frame(height: 22)
            Button { Haptics.selection(); showUnitPref = true } label: {
                HStack(spacing: 3) {
                    Text(ticket.amountUnit == .usd ? "AUSD" : market.asset).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.trailing, 10).padding(.leading, 4).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.primary)
            .accessibilityLabel("Amount unit, \(ticket.amountUnit == .usd ? "AUSD" : market.asset)")
            .accessibilityHint("Change size unit")
        }
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepperField(text: Binding<String>, placeholder: String, unit: String, step: Double) -> some View {
        HStack(spacing: 4) {
            Button { adjust(text, by: -step) } label: {
                Image(systemName: "minus").font(.subheadline.weight(.semibold)).frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Decrease price")
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad).multilineTextAlignment(.center).monospacedDigit()
                .font(.subheadline.weight(.medium))
            Button { adjust(text, by: step) } label: {
                Image(systemName: "plus").font(.subheadline.weight(.semibold)).frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Increase price")
            Text(unit).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.trailing, 12)
        }
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var slippageField: some View {
        HStack {
            Text("Slippage").font(.caption).foregroundStyle(.secondary)
            Spacer()
            TextField("0.5" as String, text: Binding(
                get: { ticket.slippageBps == 0 ? "" : NumberStyle.number(Double(ticket.slippageBps) / 100, maximumFractionDigits: 2) },
                // 0 (the default) to 50%, as the swap slippage sheet: never negative, never past 100%, never a trap.
                set: { ticket.slippageBps = min(5_000, max(0, Int(exactly: (($0.perpDouble ?? 0) * 100).rounded(.towardZero)) ?? 0)) }
            ))
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
            .font(.caption.weight(.medium)).frame(width: 60)
            Text(verbatim: "%").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var tpslFields: some View {
        VStack(spacing: 8) {
            fieldRow("Take profit", text: $ticket.takeProfitText, unit: "USD", placeholder: "Optional")
            if let m = tpMetrics { triggerMetricRow("Exp. profit", m) }
            fieldRow("Stop loss", text: $ticket.stopLossText, unit: "USD", placeholder: "Optional")
            if let m = slMetrics { triggerMetricRow("Exp. loss", m) }
            Paragraph(tpslStatus.text)
                .font(.caption2).foregroundStyle(tpslStatus.warning ? Color.attention : Color.secondary)
        }
    }

    private func checkRow(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Button {
            Haptics.selection(); isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isOn.wrappedValue ? Color.brand : Color.secondary)
                Text(label).font(.subheadline).foregroundStyle(.primary)
                Spacer()
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(isOn.wrappedValue ? [.isButton, .isSelected] : .isButton)
    }

    private func summaryRow(_ label: LocalizedStringKey, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(tint ?? .primary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Long / Short

    private var longShortButtons: some View {
        VStack(spacing: 10) {
            sideButton(.long, Text("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]"), .positive)
            sideButton(.short, Text("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]"), .negative)
            if !session.canSign {
                Text("Sign in to trade.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private func sideButton(_ side: PositionSide, _ label: Text, _ color: Color) -> some View {
        Button {
            attemptOrder(side)
        } label: {
            label
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .foregroundStyle(Color.onStatus)
                .background(color.opacity(session.canSign ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!session.canSign)
    }

    private func attemptOrder(_ side: PositionSide) {
        ticket.side = side
        if let reason = ticket.problem(market: market, mark: mark, account: model.account, available: availableMargin) {
            Haptics.warning(); ticketError = reason; return
        }
        if let reason = triggerProblem(side: side) {
            Haptics.warning(); ticketError = reason; return
        }
        if !ticket.effectiveReduceOnly, let reason = leftoverTriggerProblem(side: side) {
            Haptics.warning(); ticketError = reason; return
        }
        ticketError = nil
        reviewInput = ticket.input(market: market, refPrice: refPrice)
        reviewCloses = PerpCloseOrder.closes(orderSide: side, reduceOnly: ticket.effectiveReduceOnly, held: position?.side)
        Haptics.commit()
        // Use the authenticated path when the socket is live, OR when the wallet has an enrolled key and the user wants
        // TP/SL (its submit awaits ensureConnected()); otherwise the on-chain path. Decided here, once per confirmation.
        authedOrderAccount = (perplTrading.isReady || (perplTrading.isEnrolled && wantsTriggers)) ? model.account?.accountId : nil
        reviewLive = perplTrading.liveOutcomes
        reviewHeld = position
        reviewReadAt = model.positionsReadAt
        reviewRestingOnSide = model.orders.contains { $0.perpId == market.id && !$0.reduceOnly && ($0.side == .buy) == (side == .long) }
            || perplTrading.openOrders.contains { $0.marketId == market.id && $0.isRestingEntry && ($0.typeRaw == 1) == (side == .long) }
        // A new review: no wallet-signed order of it exists yet.
        onChainOrder = nil
        planDescId = nil
        showConfirm = true
    }

    /// A take-profit must sit on the profit side of the entry and a stop-loss on the loss side for the chosen
    /// direction. A wrong-sided trigger is what the keeper rejects or fires instantly, which would leave the position
    /// unprotected — so block it before placing (and before recording it as if it were live). Also refused (security
    /// audit GT-7, GT-8): a price that isn't a number (it would silently be left off), zero or below one tick (sent as
    /// `tp: 0`, a close that fires at once), off the market's tick, and a stop-loss at or beyond the liquidation price.
    private func triggerProblem(side: PositionSide) -> String? {
        guard ticket.effectiveTPSL else { return nil }
        // An order that only shrinks the position on the other side opens nothing for its triggers to close (GT-6).
        let wantsTriggers = [ticket.takeProfitText, ticket.stopLossText].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if wantsTriggers, let position, PerplTriggerRules.onlyReduces(side: side, size: baseSize, positionSide: position.side, positionSize: position.size) {
            return PerplTriggerRules.Problem.reducesPosition(position.side).message(market: market)
        }
        for (kind, text) in [(PerplTriggerKind.takeProfit, ticket.takeProfitText), (.stopLoss, ticket.stopLossText)] {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let price = text.perpDouble else {
                return kind == .takeProfit ? tr("Enter the take-profit as a number, or leave it empty.") : tr("Enter the stop-loss as a number, or leave it empty.")
            }
            if kind == .stopLoss, market.maintMarginFraction == nil { return PerplTriggerRules.liquidationUnknownMessage }
            if let problem = PerplTriggerRules.problem(kind, price: price, side: side, reference: refPrice, liquidation: projectedLiquidation(side: side), priceDecimals: market.priceDecimals) {
                return problem.message(market: market)
            }
        }
        return nil
    }

    // MARK: Bottom section (positions / orders / assets / trade history)

    private var bottomSection: some View {
        VStack(spacing: 14) {
            orderStatusRow
            protectionBanner
            segmentedTabs
            switch bottomTab {
            case .positions:
                if let position {
                    PositionCard(position: position, liveMark: mark, triggers: triggerRows(for: market).filter { $0.positionLong == (position.side == .long) },
                                 onClose: { closeRoute = apiRoute; closingPosition = position }, onAddMargin: { marginRoute = apiRoute; addingMargin = position },
                                 onTriggers: { editingTriggers = position })
                }
                else { emptyRow("No open positions") }
                orphanBanner
            case .orders:
                let orders = model.orders.filter { $0.perpId == market.id }
                let rows = triggerRows(for: market)
                ordersFreshnessBanner(rows: rows)
                orphanBanner
                if orders.isEmpty, rows.isEmpty { emptyRow("No open orders") }
                else {
                    ForEach(orders) { order in
                        let streamKey = PerplOpenOrder.streamOrder(for: order, in: perplTrading.openOrders, priceDecimals: market.priceDecimals)?.id
                        OrderCard(order: order, mark: mark, cancelling: streamKey.map { perplTrading.cancellingKeys.contains($0) } ?? false,
                                  gone: perplTrading.chainOrderGone(order), onCancel: { tapCancel(order) })
                    }
                    ForEach(rows) { row in
                        TriggerCard(row: row, mark: mark, cancelling: row.order.map { perplTrading.cancellingKeys.contains($0.id) } ?? false) {
                            guard let order = row.order else { return }
                            cancellingTriggers = TriggerCancelRequest(orders: [order], title: row.kind == .takeProfit ? "Cancel Take Profit" : "Cancel Stop Loss", note: nil)
                        }
                    }
                }
            case .assets:
                let total = model.account.map { Amount.units($0.balance, decimals: 6) } ?? 0
                let inUse = model.account.map { Amount.units(min($0.balance, $0.locked), decimals: 6) } ?? 0
                DetailRows {
                    DetailRow("Total balance", PriceFormat.usdValue(total))
                    DetailRow("In use (margin)", PriceFormat.usdValue(inUse))
                    DetailRow("Available", PriceFormat.usdValue(availableMargin))
                    DetailRow("Unrealized", PriceFormat.usdValue(model.unrealizedTotal, signed: true), tint: model.unrealizedTotal < 0 ? .negative : .positive)
                }
            case .history:
                historyList
            }
        }
    }

    /// Positions / Orders / Assets / Trade History as underline tabs: each title on one line at its own width, the selected one
    /// semibold without moving the others (each reserves its semibold width). When they don't all fit (a longer translation,
    /// a large text size), the row scrolls sideways instead of wrapping, keeping the selected tab in view.
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

    /// Says when the TP/SL list can't be verified (security audit GT-3): the trading stream isn't live, so rows are
    /// the last list Perpl sent or this device's own record, and triggers set elsewhere don't show — or it is live but a
    /// heartbeat gap means some of Perpl's updates may have been missed (I10).
    @ViewBuilder private func ordersFreshnessBanner(rows: [TriggerRow]) -> some View {
        if !perplTrading.ordersAreLive, perplTrading.isEnrolled || !rows.isEmpty {
            freshnessNote(Paragraph("TP/SL can't be verified right now: Perpl trading is offline. Rows below may be out of date, and orders placed on other devices or the Perpl web app don't show."))
        } else if perplTrading.ordersAreLive, perplTrading.streamSuspect {
            freshnessNote(Paragraph(LocalizedStringResource("TP/SL may be out of date: some updates from Perpl may have been missed. Reconnect in Profile → Perpl Trading to refresh them.",
                                                            comment: "The Perps Orders tab's warning: the trading connection is up, but a gap in Perpl's heartbeat means some order updates may have been missed, so the take-profit / stop-loss rows may be out of date. Profile → Perpl Trading is where the connection is managed.")))
        }
    }

    private func freshnessNote(_ paragraph: Paragraph) -> some View {
        Label { paragraph } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .modifier(ParagraphLabel())
            .font(.footnote).foregroundStyle(Color.attention)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// TP/SL left on this market with no position to close (security audit GT-2): left armed, they would fire on the
    /// next position on that side. Offered for cancelling in one tap (the app cancels them itself for a key account
    /// once it sees the position close; a passkey account's cancel needs Face ID, so it lands here). Never those a
    /// cancel is already on its way for, or that the automatic clean-up is about to cancel: a tap would send a second.
    /// Those are said to be cancelling instead (no button), so the banner neither flashes away nor offers them twice
    /// (I32); still listed after those windows, they are offered again.
    @ViewBuilder private var orphanBanner: some View {
        let orphans = orphansToOffer
        let cancelling = orphansBeingCancelled
        if !orphans.isEmpty || !cancelling.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !orphans.isEmpty {
                    Label {
                        Paragraph("\(orphans.count) TP/SL on \(market.asset) have no position to close. Left armed, they would fire on your next position here.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .modifier(ParagraphLabel())
                    .font(.footnote).foregroundStyle(Color.attention)
                    Button(orphans.count == 1 ? "Cancel It" : "Cancel Them") {
                        cancellingTriggers = TriggerCancelRequest(orders: orphans, title: "Leftover TP/SL", note: "There is no open position on \(market.asset) for these to close.")
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.negative)
                }
                if !cancelling.isEmpty {
                    Label {
                        Paragraph(verbatim: PerpTriggerCopy.cancellingLeftovers(count: cancelling.count, asset: market.asset))
                    } icon: {
                        ProgressView().controlSize(.mini)
                    }
                    .modifier(ParagraphLabel())
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// The newest order sent from this market whose sheet is closed: still waiting for Perpl, or its result until it is
    /// seen (a success leaves after a few seconds, a warning or a failure stays until dismissed). The timeline re-reads
    /// it every second, for the success's time out.
    @ViewBuilder private var orderStatusRow: some View {
        if perplTrading.orders.orders.contains(where: { $0.marketId == market.id }) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let order = perplTrading.orders.bannerOrder(marketId: market.id, now: context.date) {
                    PerpOrderStatusRow(order: order) { perplTrading.orders.dismissBanner(order.id) }
                }
            }
        }
    }

    /// A fired or failed TP/SL, or a liquidation, reported by the trading stream (security audit GT-9) — shown here as
    /// well as in notifications, until dismissed.
    @ViewBuilder private var protectionBanner: some View {
        if let notice = perplTrading.protectionNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.warning ? "exclamationmark.triangle.fill" : "bell.fill")
                    .foregroundStyle(notice.warning ? Color.attention : Color.brand)
                VStack(alignment: .leading, spacing: 3) {
                    Paragraph(notice.title).font(.subheadline.weight(.semibold))
                    Paragraph(notice.body).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button { perplTrading.dismissProtectionNotice() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 12)
            .background((notice.warning ? Color.attention : Color.brand).opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }

    private func emptyRow(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    // MARK: Trade history (this market)

    @ViewBuilder private var historyList: some View {
        if perplTrading.key == nil {
            // A passkey account's key exists only while its session is live; the history needs it to sign the reads.
            emptyRow(perplTrading.isEnrolled ? "Your Perpl history loads while your passkey session is unlocked." : "Connect Perpl trading in Profile to see your history.")
        } else if let fillsError {
            InlineError(message: fillsError)
        } else if loadingFills, fills.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if fills.isEmpty {
            emptyRow("No trades on \(market.asset)-PERP yet")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(fills.prefix(50)) { fill in
                    historyRow(fill)
                    if fill.id != fills.prefix(50).last?.id { Divider() }
                }
            }
        }
    }

    private func historyRow(_ fill: PerplFill) -> some View {
        let pnl: Double? = fill.isClose ? pnlByOrder[fill.orderId] : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(fill.direction).font(.subheadline.weight(.semibold))
                    .foregroundStyle(fill.side == .buy ? Color.positive : Color.negative)
                Spacer()
                Text(fill.time, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .trailing)], spacing: 6) {
                historyStat("Price", NumberStyle.number(fill.price), align: .leading)
                historyStat("Size", "\(NumberStyle.number(fill.size, maximumFractionDigits: 4)) \(fill.symbol)", align: .leading)
                historyStat("Value", PriceFormat.usdValue(fill.notional), align: .trailing)
                historyStat("Fee", PriceFormat.usdValue(fill.fee), align: .leading)
                Color.clear.frame(height: 0)
                pnlStat(pnl)
            }
        }
        .padding(.vertical, 10)
    }

    private func historyStat(_ label: LocalizedStringKey, _ value: String, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: align == .trailing ? .trailing : .leading)
    }

    @ViewBuilder private func pnlStat(_ pnl: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("PnL").font(.caption2).foregroundStyle(.secondary)
            if let pnl {
                Text(PriceFormat.usdValue(pnl, signed: true))
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(pnl < 0 ? Color.negative : (pnl > 0 ? Color.positive : Color.primary))
            } else {
                Text(verbatim: "—").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func loadFills() async {
        guard let key = perplTrading.key else { fills = []; pnlByOrder = [:]; fillsError = nil; return }
        loadingFills = fills.isEmpty
        defer { loadingFills = false }
        let markets = model.markets.isEmpty ? [market] : model.markets
        do {
            let fillPage = try await env.perpl.fills(key: key, markets: markets, count: 100)
            fills = fillPage.items.filter { $0.marketId == market.id }
            fillsError = nil
            if let pnlPage = try? await env.perpl.positionHistory(key: key, markets: markets, count: 100) {
                pnlByOrder = Dictionary(pnlPage.items.filter { $0.marketId == market.id }.map { ($0.orderId, $0.realizedPnl) }, uniquingKeysWith: +)
            }
        } catch {
            if fills.isEmpty { fillsError = describe(error) }
        }
    }

    // MARK: Confirmation

    /// The order under review (`reviewInput`), or the live ticket when no review is open.
    private var reviewedInput: OrderInput { reviewInput ?? ticket.input(market: market, refPrice: refPrice) }

    @ViewBuilder private var orderConfirmSheet: some View {
        // Use the authenticated (keeper-forwarded) path when the socket is live, OR when the wallet has an enrolled key
        // and the user wants TP/SL — its submit() awaits ensureConnected(), so a socket that idled to `.enrolled` still
        // reconnects and carries the triggers instead of silently dropping to a bare on-chain entry. A plain order with
        // no triggers still falls through to the on-chain path when not live, so trading never depends on one-click.
        if let accountId = authedOrderAccount {
            AuthedOrderSheet(market: market, input: reviewedInput, takeProfit: tpValue, stopLoss: slValue, accountId: accountId, sideColor: sideColor, summaryMargin: notional / max(ticket.leverage, 1),
                             triggerSize: invertedSize(side: ticket.side), triggerNote: turnaroundNote, onChainPositions: model.positions, onChainOrders: model.orders,
                             live: reviewLive, closes: reviewCloses, held: reviewHeld.map { ($0.side, $0.size) }, ttlBlocks: model.context[market.id]?.orderTTLBlocks,
                             markets: model.markets, before: reviewHeld, beforeReadAt: reviewReadAt, restingOnSide: reviewRestingOnSide,
                             onSent: { if let reviewCloses { model.noteUserClose(market.id, closing: reviewCloses) } }) { clearTicket in
                // An order that provably executed nothing stays in the ticket, ready to send again (a new tap).
                if clearTicket { ticket.sizeText = ""; ticket.takeProfitText = ""; ticket.stopLossText = ""; sizePercent = 0 }
                Task { await model.load(env: env, address: session.address) }
            }
        } else {
            confirmSheet
        }
    }

    /// The on-chain order: signed in the wallet, sent as a transaction, and — once it confirms — read from its receipt:
    /// the sheet holds "done" until it can say what the order did (filled, partly filled, resting, or nothing filled).
    private var confirmSheet: some View {
        ConfirmationSheet(title: "Review Order", confirmTitle: ticket.side == .long ? "Long \(market.asset)" : "Short \(market.asset)", build: { try await checkedOrderPlan() }, onDone: {
            // An order that provably executed nothing stays in the ticket, ready to send again (a new tap).
            if PerplTracker.clearsTicket(onChainOrder.flatMap { perplTrading.orders.order($0)?.entry }) { ticket.sizeText = ""; sizePercent = 0 }
            Task { await model.load(env: env, address: session.address) }
        }, onCompleted: { hash in
            if let reviewCloses { model.noteUserClose(market.id, closing: reviewCloses) }
            // At the receipt (GL-3): its row says it was sent and its result isn't read yet (no volume until a fill is), and
            // it is followed until its receipt is read, even if the app is killed first.
            let id = onChainOrder ?? UUID()
            onChainOrder = id
            perplTrading.trackOnChain(id: id, hash: hash, input: reviewedInput, closes: reviewCloses, held: reviewHeld.map { ($0.side, $0.size) },
                                      accountId: model.account?.accountId, descId: planDescId, owner: session.address)
        }, intent: orderIntent, onStarted: {
            // A confirm tried again after one that sent nothing: that one expects no fill any more.
            if let previous = onChainOrder { perplTrading.onChainSheetClosed(previous) }
            // The app-wide watcher waits for this order's own result rather than announcing its fill first (I5).
            onChainOrder = perplTrading.expectOnChainOrder(reviewedInput, held: reviewHeld.map { ($0.side, $0.size) })
        }, settle: { _ in
            guard let id = onChainOrder else { return nil }
            return await perplTrading.settleOnChainOrder(id)
        }) {
            let signed = reviewedInput
            DetailRow(Text(verbatim: tr(LocalizedStringResource("orderReview.market", defaultValue: "Market", comment: "A review row: the Perps market the order is on, next to its name (BTC-PERP) [tight]"))), Text(verbatim: "\(market.asset)-PERP"))
            DetailRow("Side", ticket.side == .long ? "Long" : "Short", tint: sideColor)
            if signed.kind == .limit, let flagged = PerpOrderCopy.limitType(price: NumberStyle.number(signed.price ?? mark, maximumFractionDigits: market.priceDecimals), postOnly: signed.postOnly, reduceOnly: signed.reduceOnly) {
                DetailRow("Type", verbatim: flagged)
            } else {
                DetailRow("Type", ticket.kind == .market ? "Market · \(NumberStyle.basisPoints(ticket.slippageBps)) slippage" : "Limit at \(NumberStyle.number(signed.price ?? mark, maximumFractionDigits: market.priceDecimals))")
            }
            // The parsed values this order signs, not the typed text (audit F4), at the market's full precision.
            DetailRow("Size", verbatim: "\(NumberStyle.number(signed.size, maximumFractionDigits: market.lotDecimals)) \(market.asset)")
            DetailRow("Leverage", verbatim: "\(NumberStyle.number(ticket.leverage, maximumFractionDigits: 1))×")
            DetailRow("Margin", PriceFormat.usdValue(notional / max(ticket.leverage, 1)))
            // This path (perplTrading not ready) places a bare on-chain entry — it cannot attach TP/SL. Don't advertise
            // triggers the order won't carry; tell the user they need one-click trading for them.
            if ticket.effectiveTPSL, !ticket.takeProfitText.isEmpty || !ticket.stopLossText.isEmpty {
                DetailRow("TP/SL", "Needs one-click trading — not placed", tint: .attention)
            }
            if !ticket.effectiveReduceOnly, let leftover = leftoverTriggerProblem(side: ticket.side) {
                // The stream came up after the plan was prepared: the check runs here too.
                Text(leftover).font(.footnote).foregroundStyle(Color.attention)
            } else if leftoversUnchecked {
                Text(ticket.side == .long
                     ? "Take-profit and stop-loss left from an earlier \(market.asset) long can't be checked while Perpl trading is offline. If you had any, check Orders first: they would act on this position."
                     : "Take-profit and stop-loss left from an earlier \(market.asset) short can't be checked while Perpl trading is offline. If you had any, check Orders first: they would act on this position.")
                    .font(.footnote).foregroundStyle(Color.attention)
            }
        }
    }

    /// An on-chain opening order, valued at its worst-case notional and declared by its terms (market, side, size,
    /// leverage), which the wallet checks against the calldata it signs; a reduce-only close always asks (MERA-PLAN §3).
    private var orderIntent: Mera.Intent {
        let input = reviewedInput
        return input.reduceOnly ? .alwaysAsks(.closePosition) : .perplOrder(usd: Mera.SpendingCaps.notionalUSD(of: input), order: .init(input))
    }

    /// A Cancel tap on a resting order. Perpl's live list already showed a cancel from this device took it: no sheet, and
    /// the chain is read again. The stream's word alone that it left (no cancel from here) never refuses the wallet's
    /// cancel: the chain is read again, and if it still lists the order its wallet sheet opens.
    /// Otherwise the path is fixed here (A.2): Perpl's API when one-click is live for this account, its list is live and
    /// not suspect, and the stream's order matches the chain's by its smart contract order id; else the wallet's cancel.
    private func tapCancel(_ order: PerpOrder) {
        if let gone = perplTrading.chainOrderGone(order) {
            if gone.byCancel { Haptics.warning() }
            Task {
                await model.load(env: env, address: session.address)
                guard !gone.byCancel else { return }
                guard let fresh = model.orders.first(where: { PerplTrading.ChainOrderKey($0) == PerplTrading.ChainOrderKey(order) }) else {
                    Haptics.warning()
                    return
                }
                cancelTarget = nil
                cancelTapRq = nil
                cancelAccount = nil
                cancellingOrder = fresh
            }
            return
        }
        if let account = actionAccount, perplTrading.apiActionsLive(for: account), perplTrading.ordersAreLive, !perplTrading.streamSuspect {
            cancelTarget = PerplOpenOrder.streamOrder(for: order, in: perplTrading.openOrders, priceDecimals: market.priceDecimals)
            cancelTapRq = cancelTarget.flatMap { perplTrading.requestId(for: $0.id) }
            cancelAccount = account
        } else {
            cancelTarget = nil
            cancelTapRq = nil
            cancelAccount = nil
        }
        cancellingOrder = order
    }

    private func cancelOrderSheet(_ order: PerpOrder) -> some View {
        let size = NumberStyle.number(order.size)
        let price = NumberStyle.number(order.price)
        let what = order.side == .buy ? tr("Buy \(size) at \(price)") : tr("Sell \(size) at \(price)")
        return ConfirmationSheet(title: "Cancel Order", confirmTitle: "Cancel Order", build: { env.perpl.cancelPlan(perpId: order.perpId, orderId: order.orderId) }, onDone: { Task { await model.load(env: env, address: session.address) } },
                          onCompleted: { hash in Activity.record(ActivityRecord(kind: .perp, title: tr("Cancelled \(order.symbol) order"), subtitle: what, hash: hash, section: "perps"), owner: session.address) },
                          intent: .alwaysAsks(.cancelOrder)) {
            DetailRow(Text(verbatim: tr(LocalizedStringResource("orderReview.market", defaultValue: "Market", comment: "A review row: the Perps market the order is on, next to its name (BTC-PERP) [tight]"))), Text(verbatim: order.symbol))
            DetailRow("Order", verbatim: what)
        }
    }

    // MARK: TP/SL helpers

    private var tpValue: Double? { ticket.effectiveTPSL ? ticket.takeProfitText.perpDouble : nil }
    private var slValue: Double? { ticket.effectiveTPSL ? ticket.stopLossText.perpDouble : nil }
    /// The user is asking for at least one trigger — which only the authenticated (keeper-forwarded) path can carry.
    private var wantsTriggers: Bool { tpValue != nil || slValue != nil }

    /// The market's TP/SL to show: Perpl's authoritative open triggers (mt:23/24, source of truth), plus — only
    /// briefly after placement, or while the trading socket is offline — the app's local echo for a kind the
    /// authoritative feed hasn't reflected yet. Once the feed confirms a trigger, the echo for that kind drops out.
    /// "Live" means the stream is signed in and has sent its snapshot (one-click on or not); otherwise every row says it
    /// can't be verified (security audit GT-3).
    private func triggerRows(for market: PerpMarket) -> [TriggerRow] {
        let priceScale = pow(10.0, Double(market.priceDecimals))
        let sizeScale = pow(10.0, Double(market.lotDecimals))
        // A heartbeat gap since the snapshots means updates may have been missed: the rows say "Last seen on Perpl" (I10).
        let live = perplTrading.ordersAreLive && !perplTrading.streamSuspect
        let positionSize = { (long: Bool) -> Double? in position.flatMap { ($0.side == .long) == long ? $0.size : nil } }
        let authoritative = perplTrading.openOrders
            .filter { $0.marketId == market.id && $0.isTrigger && $0.isReduceOnly }
            .map { o in
                TriggerRow(id: "auth-\(o.marketId)-\(o.oid)", symbol: market.asset, kind: o.isStopLoss ? .stopLoss : .takeProfit,
                           price: Double(o.triggerPriceRaw ?? 0) / priceScale, size: Double(o.sizeRaw) / sizeScale,
                           positionLong: o.protectsLong, source: live ? .live : .lastKnown, order: o, positionSize: positionSize(o.protectsLong))
            }
        let authKinds = Set(authoritative.map(\.kind))
        let echo = model.triggers
            .filter { $0.perpId == market.id && !authKinds.contains($0.kind) && (!live || Date().timeIntervalSince($0.placedAt) < 10) }
            .map { TriggerRow(id: "echo-\($0.id)", symbol: $0.symbol, kind: $0.kind, price: $0.price, size: $0.size, positionLong: $0.positionLong,
                              source: live ? .pending : .unverified, order: nil, positionSize: positionSize($0.positionLong)) }
        return authoritative + echo
    }

    /// The live TP/SL closing `position`'s side on this market.
    private func triggersProtecting(_ position: PerpPosition) -> [PerplOpenOrder] {
        guard perplTrading.ordersAreLive else { return [] }
        return perplTrading.openOrders.filter { $0.marketId == market.id && $0.isTrigger && $0.isReduceOnly && $0.protectsLong == (position.side == .long) }
    }

    /// This market's TP/SL with no position left to close (security audit GT-2).
    private var orphanedTriggers: [PerplOpenOrder] {
        perplTrading.orphanedTriggers(onChainPositions: model.positions, onChainOrders: model.orders).filter { $0.marketId == market.id }
    }

    /// This market's orphaned TP/SL that no cancel is already on its way for (`PerplTrading.orphansToOffer`).
    private var orphansToOffer: [PerplOpenOrder] {
        perplTrading.orphansToOffer(onChainPositions: model.positions, onChainOrders: model.orders).filter { $0.marketId == market.id }
    }

    /// This market's orphaned TP/SL a cancel is on its way for, or that the automatic clean-up is about to cancel.
    private var orphansBeingCancelled: [PerplOpenOrder] {
        perplTrading.orphansBeingCancelled(onChainPositions: model.positions, onChainOrders: model.orders).filter { $0.marketId == market.id }
    }

    /// Leftover TP/SL on this side of the market (security audit GT-2) would act on the position this order opens: a
    /// stop-loss left from an earlier position can fire the moment it exists. They are cancelled first. Checked again
    /// where the order is sent: `PerplTrading.submitBracket` for a one-click order, `checkedOrderPlan` on-chain.
    private func leftoverTriggerProblem(side: PositionSide) -> String? {
        let leftovers = orphanedTriggers.filter { $0.protectsLong == (side == .long) }
        guard !leftovers.isEmpty else { return nil }
        return PerplTrading.leftoverMessage(count: leftovers.count, asset: market.asset, side: side)
    }

    /// The on-chain order's plan, once the leftover TP/SL check has run on Perpl's live lists (GT-2). The stream is
    /// brought up first when it can be without a prompt; a passkey account's stays down until its session opens, and
    /// the review says the check couldn't run (`leftoversUnchecked`).
    private func checkedOrderPlan() async throws -> [TransactionStep] {
        let input = reviewedInput
        if !input.reduceOnly {
            if perplTrading.isEnrolled, !(perplTrading.ordersAreLive && perplTrading.positionsAreLive) {
                await perplTrading.awaitLiveStream(timeout: 4)
            }
            if let problem = leftoverTriggerProblem(side: input.side) { throw PerplTradeError.invalidOrder(problem) }
        }
        let plan = env.perpl.orderPlan(input)
        // The id this very plan signs: its request is found by it in the receipt.
        planDescId = PerplReceipt.descId(ofPlan: plan)
        return plan
    }

    /// An opening order whose leftover TP/SL check can't run: Perpl trading is enrolled but its stream isn't live.
    private var leftoversUnchecked: Bool {
        !ticket.effectiveReduceOnly && perplTrading.isEnrolled && !(perplTrading.ordersAreLive && perplTrading.positionsAreLive)
    }
    private var sideColor: Color { ticket.side == .long ? .positive : .negative }

    /// For an order that turns the position around (GT-6): what its triggers act on, in the app's language. The order is
    /// on the other side of the position, so a long turns into a short or a short into a long.
    private var turnaroundNote: String? {
        guard wantsTriggers, let position, let residual = invertedSize(side: ticket.side) else { return nil }
        let held = "\(NumberStyle.number(position.size)) \(market.asset)"
        let opened = "\(NumberStyle.number(residual)) \(market.asset)"
        return ticket.side == .long
            ? tr("This order closes your \(held) short and opens a \(opened) long: its take-profit and stop-loss close that long only.")
            : tr("This order closes your \(held) long and opens a \(opened) short: its take-profit and stop-loss close that short only.")
    }

    /// What to tell the user about whether their take-profit / stop-loss will actually be placed, and whether it needs
    /// them to act. An enrolled key means the triggers WILL be placed (the order path reconnects on submit), so that
    /// is reassurance, not a warning — only `notEnrolled` / `needsForwarding` / a hard failure require an action.
    private var tpslStatus: (text: String, warning: Bool) {
        switch perplTrading.status {
        case .connected:
            // Sized to this order, and they stay that size (security audit GT-5): say so, rather than "linked to this
            // position", and point at the position's own TP/SL for the whole of it.
            let size = "\(NumberStyle.number(baseSize)) \(market.asset)"
            if let position {
                let whole = "\(NumberStyle.number(position.size)) \(market.asset)"
                return (baseSize > 0
                    ? tr("Placed on Perpl as keeper triggers that close this order's size only (\(size)), not your whole \(whole) position. For all of it, use TP/SL on the position.")
                    : tr("Placed on Perpl as keeper triggers that close this order's size only, not your whole \(whole) position. For all of it, use TP/SL on the position."), false)
            }
            return (baseSize > 0
                ? tr("Placed on Perpl as keeper triggers that close this order's size (\(size)). The size is fixed: they don't grow if you add to the position later.")
                : tr("Placed on Perpl as keeper triggers that close this order's size. The size is fixed: they don't grow if you add to the position later."), false)
        case .connecting, .enrolled:
            return (tr("Connecting to Perpl trading to place your take-profit and stop-loss."), false)
        case .needsForwarding:
            return (tr("Enable one-click trading in Profile to place take-profit and stop-loss."), true)
        case .notEnrolled:
            return (tr("Connect Perpl trading in Profile to place take-profit and stop-loss."), true)
        case .failed:
            return (tr("Couldn’t reach Perpl trading — retrying. Take-profit and stop-loss need it live."), true)
        }
    }

    /// Expected result at a take-profit / stop-loss trigger, measured from the entry (`refPrice` — the limit price for
    /// a limit order, else the mark). The ticket's side isn't chosen until the user taps Long or Short, so the sign
    /// follows the trigger's ROLE, not a not-yet-chosen (and defaulted-to-long) side: a take-profit is by definition a
    /// gain and a stop-loss a loss, and the magnitude is the price distance from entry × size. This reads correctly
    /// for both directions — a short's TP sits below entry, a long's above, but each is |trigger − entry| away.
    private func triggerMetrics(_ trigger: Double?, isProfit: Bool) -> (pct: Double, pnl: Double)? {
        guard let trigger, trigger > 0, refPrice > 0, baseSize > 0 else { return nil }
        let distance = abs(trigger - refPrice)
        let signed = isProfit ? distance : -distance
        return (signed / refPrice * 100, signed * baseSize)
    }
    private var tpMetrics: (pct: Double, pnl: Double)? { triggerMetrics(tpValue, isProfit: true) }
    private var slMetrics: (pct: Double, pnl: Double)? { triggerMetrics(slValue, isProfit: false) }

    private func triggerMetricRow(_ label: LocalizedStringKey, _ m: (pct: Double, pnl: Double)) -> some View {
        HStack {
            // The label is a key, the amount is shown as it is: one line, never a placeholder-only key.
            Text(label) + Text(verbatim: " \(PriceFormat.usdValue(m.pnl, signed: true))")
            Spacer()
            Text(NumberStyle.percent(m.pct))
        }
        .font(.caption2).monospacedDigit()
        .foregroundStyle(m.pnl >= 0 ? Color.positive : Color.negative)
    }

    private func fieldRow(_ title: LocalizedStringKey, text: Binding<String>, unit: String, placeholder: LocalizedStringKey) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            TextField(placeholder, text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().fontWeight(.medium)
            Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Funding

    private var fundingText: String { NumberStyle.percent(Double(market.fundingRatePct100k) / 1_000, fractionDigits: 4) }
    private var fundingTint: Color { market.fundingRatePct100k < 0 ? .negative : market.fundingRatePct100k > 0 ? .positive : .secondary }
    private func countdownText(now date: Date = Date()) -> String {
        let now = date.timeIntervalSince1970
        let secs = 3600 - Int(now.truncatingRemainder(dividingBy: 3600))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    // MARK: Derived values

    /// 1x while the margin read has failed: the venue's limit is unknown, and it is never guessed.
    private var maxLeverage: Double { max(1, (1 / max(market.initMarginFraction ?? 1, 0.01)).rounded(.down)) }
    /// What a liquidation price that can't be computed reads as: unknown when the maintenance margin couldn't be read
    /// (never a guessed 5%, which would understate the risk), a dash when there is nothing to compute yet.
    private var liquidationFallback: String { market.maintMarginFraction == nil ? PositionText.unknown : "—" }
    private var minSize: Double { pow(10, -Double(market.lotDecimals)) }
    private func referencePrice(_ type: PriceType) -> Double {
        switch type {
        case .last: return live?.last ?? mark
        case .mid: return live?.mid ?? mark
        }
    }
    private var refPrice: Double { ticket.kind == .limit ? (ticket.priceText.perpDouble ?? mark) : mark }
    private var baseSize: Double { ticket.baseSize(market: market, price: refPrice) }
    private var notional: Double { baseSize * refPrice }
    private var estFee: Double { notional * 0.00069 }
    private var maxNotional: Double { availableMargin * ticket.leverage }
    private var priceStep: Double { pow(10, -Double(market.priceDecimals)) * 10 }
    private var amountStep: Double { ticket.amountUnit == .usd ? 1 : minSize * 10 }

    private var liquidationLong: Double? {
        guard baseSize > 0 else { return nil }
        let margin = notional / max(ticket.leverage, 1)
        return PerplService.liquidationPrice(side: .long, entry: refPrice, size: baseSize, margin: margin, premium: 0, maintenanceFraction: market.maintMarginFraction)
    }
    private var liquidationShort: Double? {
        guard baseSize > 0 else { return nil }
        let margin = notional / max(ticket.leverage, 1)
        return PerplService.liquidationPrice(side: .short, entry: refPrice, size: baseSize, margin: margin, premium: 0, maintenanceFraction: market.maintMarginFraction)
    }
    /// The liquidation price the position will have after this order, to check a stop-loss against (security audit
    /// GT-8): the order's own when it opens a position, the combined one when it adds to a position on the same side,
    /// and the new side's when it turns a position around (GT-6: its triggers act on what is left on that side).
    private func projectedLiquidation(side: PositionSide) -> Double? {
        guard baseSize > 0, refPrice > 0 else { return nil }
        let margin = notional / max(ticket.leverage, 1)
        if let position, position.side == side, position.size > 0 {
            let size = position.size + baseSize
            let entry = (position.entry * position.size + refPrice * baseSize) / size
            return PerplService.liquidationPrice(side: side, entry: entry, size: size, margin: position.margin + margin, premium: position.premium, maintenanceFraction: market.maintMarginFraction)
        }
        if let residual = invertedSize(side: side) {
            return PerplService.liquidationPrice(side: side, entry: refPrice, size: residual, margin: residual * refPrice / max(ticket.leverage, 1), premium: 0, maintenanceFraction: market.maintMarginFraction)
        }
        return PerplService.liquidationPrice(side: side, entry: refPrice, size: baseSize, margin: margin, premium: 0, maintenanceFraction: market.maintMarginFraction)
    }

    /// The size left on `side` when this order turns the open position on the other side around, or nil when it
    /// doesn't.
    private func invertedSize(side: PositionSide) -> Double? {
        guard let position, position.side != side, position.size > 0, baseSize > 0,
              !PerplTriggerRules.onlyReduces(side: side, size: baseSize, positionSide: position.side, positionSize: position.size) else { return nil }
        return baseSize - position.size
    }

    private var chartLevels: [ChartLevel] {
        var out: [ChartLevel] = []
        // Each line's title is on the chart's price axis, in the app's language.
        if let position {
            out.append(ChartLevel(price: position.entry, colorHex: position.side == .long ? "#1F9E5B" : "#D2483F",
                                  title: tr(LocalizedStringResource("Entry", comment: "The position's entry price: a chart line and a stat on the position [tight]"))))
            if let liq = position.liquidation, liq > 0 {
                out.append(ChartLevel(price: liq, colorHex: "#F5A623", title: tr(LocalizedStringResource("Liq", comment: "A chart line at the liquidation price, short for Liquidation. [tight]")), dashed: true))
            }
        }
        for order in model.orders where order.perpId == market.id {
            out.append(ChartLevel(price: order.price, colorHex: order.side == .buy ? "#1F9E5B" : "#D2483F",
                                  title: order.reduceOnly ? tr(LocalizedStringResource("chartLine.close", defaultValue: "Close", comment: "A chart line at a resting order that closes the position (a noun, as the order's name). [tight]"))
                                                          : tr(LocalizedStringResource("Limit", comment: "Order type: rests at the price you set until it fills. [tight]")),
                                  dashed: true))
        }
        return out
    }

    /// "Long 5×" or "Short 5×": a position's side and its leverage.
    static func sideLeverage(_ position: PerpPosition) -> Text {
        let leverage = NumberStyle.number(position.leverage, maximumFractionDigits: 1)
        return position.side == .long ? Text("Long \(leverage)×") : Text("Short \(leverage)×")
    }

    @ViewBuilder private var positionBadge: some View {
        if let position {
            let dir = position.side == .long ? 1.0 : -1.0
            let pnl = dir * (mark - position.entry) * position.size + position.premium
            HStack(spacing: 6) {
                PerpTradeView.sideLeverage(position)
                    .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                Text(PriceFormat.usdValue(pnl, signed: true))
                    .foregroundStyle(pnl < 0 ? Color.negative : Color.positive)
            }
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
        }
    }

    private var availableMargin: Double {
        guard let account = model.account else { return 0 }
        return Amount.units(account.balance - min(account.balance, account.locked), decimals: 6)
    }

    // MARK: Mutations

    private func applyPercent(_ pct: Double) {
        guard refPrice > 0 else { return }
        // The slider owns sizePercent here; skip the amount-field's resync so it doesn't overwrite the live drag value.
        suppressPercentSync = true
        let size = availableMargin * (pct / 100) * ticket.leverage / refPrice
        let stepped = (size * pow(10, Double(market.lotDecimals))).rounded(.down) / pow(10, Double(market.lotDecimals))
        guard stepped > 0 else { ticket.sizeText = ""; return }
        ticket.sizeText = ticket.amountUnit == .usd ? plainSize(stepped * refPrice) : plainSize(stepped)
        ticketError = nil
    }

    /// Recomputes the size slider's percentage from the currently-entered size, so typing an amount, tapping the +/-
    /// steppers, or switching the size unit keeps the slider honest. Exact inverse of `applyPercent`.
    private func syncPercentFromSize() {
        guard availableMargin > 0, refPrice > 0, baseSize > 0 else { sizePercent = 0; return }
        sizePercent = min(100, notional / max(ticket.leverage, 1) / availableMargin * 100)
    }

    /// Keeps the entered size within the newly-chosen leverage's affordable notional after a leverage change.
    private func clampSizeToMargin() {
        guard sizePercent > 0 else { return }
        applyPercent(sizePercent)
    }

    private func convertAmount(to unit: OrderTicket.AmountUnit) {
        let base = ticket.baseSize(market: market, price: refPrice)
        ticket.amountUnit = unit
        guard base > 0, refPrice > 0 else { return }
        ticket.sizeText = unit == .usd ? plainSize(base * refPrice) : plainSize(base)
    }

    private func adjustAmount(_ delta: Double) {
        Haptics.selection()
        let current = ticket.sizeText.perpDouble ?? 0
        let next = max(0, current + delta)
        ticket.sizeText = next == 0 ? "" : plainSize(next)
        ticketError = nil
    }

    private func adjust(_ text: Binding<String>, by delta: Double) {
        Haptics.selection()
        let current = text.wrappedValue.perpDouble ?? mark
        let next = max(0, current + delta)
        text.wrappedValue = plainSize(next)
    }

    private func plainSize(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = max(market.priceDecimals, market.lotDecimals, 2)
        f.minimumFractionDigits = 0
        return f.string(from: value as NSNumber) ?? String(value)
    }

    /// Reads the current timeframe's candles. The answer only counts for the timeframe it was asked for; a failed read
    /// keeps that timeframe's last candles (marked not updating) but never another timeframe's (RS-10).
    private func loadCandles(showSpinner: Bool = true) async {
        let requested = resolution
        if showSpinner { loadingCandles = true }
        let to = Date()
        let from = to.addingTimeInterval(-Double(requested) * 150)
        let fetched = try? await env.perpl.candles(marketId: market.id, resolution: requested, from: from, to: to, priceDecimals: market.priceDecimals)
        // Cut short (the screen closed), or another timeframe was picked meanwhile and its own read follows.
        guard !Task.isCancelled, requested == resolution else { return }
        loadingCandles = false
        if let fetched {
            candles = fetched
            candlesResolution = requested
            candlesFailed = false
        } else {
            if candlesResolution != requested { candles = []; candlesResolution = nil }
            candlesFailed = true
        }
    }
}

// MARK: - Side order book (compact ladder shown beside the ticket, wide version under the chart)

struct SideOrderBook: View {
    let book: OrderBook
    let mark: Double
    /// Perpl's own mid (falls back to book mid / mark). Rendered as the big centered price between the ladders — using
    /// bestBid there duplicated the top bid row directly below it.
    var mid: Double? = nil
    var changePct: Double? = nil
    let symbol: String
    let priceDecimals: Int
    var rows: Int = 8
    var wide: Bool = false

    /// Tick-size grouping (wide book only). 0 = raw; higher indices aggregate price levels so a deep book reads at a
    /// glance. @State resets to raw when the market changes, since the whole trade view is rebuilt with `.id(market.id)`.
    @State private var groupIndex = 0

    private var midTint: Color { (changePct ?? 0) < 0 ? .negative : .positive }
    private var centerPrice: Double {
        if let mid { return mid }
        if let b = book.bestBid, let a = book.bestAsk { return (a + b) / 2 }
        return book.bestBid ?? mark
    }
    private var tick: Double { pow(10, -Double(priceDecimals)) }
    private let groupMultipliers = [1, 10, 100]
    private var groupMultiplier: Int { groupMultipliers[min(groupIndex, groupMultipliers.count - 1)] }
    private var group: Double { tick * Double(groupMultiplier) }

    var body: some View {
        VStack(alignment: .leading, spacing: wide ? 3 : 2) {
            HStack(spacing: 6) {
                Text("Price").font(.caption2).foregroundStyle(.secondary)
                if wide {
                    Menu {
                        ForEach(groupMultipliers.indices, id: \.self) { i in
                            Button(NumberStyle.number(tick * Double(groupMultipliers[i]))) { Haptics.selection(); groupIndex = i }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(NumberStyle.number(group)).font(.caption2.weight(.semibold))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Color.brand)
                    }
                    .accessibilityLabel("Price grouping \(NumberStyle.number(group))")
                }
                Spacer()
                Text("Total (\(symbol))").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            if book.isEmpty {
                Text("Waiting for the book…").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                let asks = cumulative(Array(aggregated(book.asks, up: true).prefix(rows)))   // ascending, cumulative from mid
                let bids = cumulative(Array(aggregated(book.bids, up: false).prefix(rows)))
                let maxTotal = max(asks.map(\.total).max() ?? 1, bids.map(\.total).max() ?? 1)

                ForEach(asks.reversed(), id: \.price) { level in
                    bookRow(level, side: "Ask", tint: .negative, maxTotal: maxTotal)
                }

                HStack(spacing: 6) {
                    Text(NumberStyle.number(centerPrice))
                        .font((wide ? Font.headline : Font.subheadline).weight(.bold)).monospacedDigit()
                        .foregroundStyle(midTint)
                    if wide, let spread = book.spread {
                        Spacer()
                        Text("Spread \(NumberStyle.number(spread))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, wide ? 6 : 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(book.spread.map { Text("Mid price \(NumberStyle.number(centerPrice)), spread \(NumberStyle.number($0))") }
                                    ?? Text("Mid price \(NumberStyle.number(centerPrice))"))

                ForEach(bids, id: \.price) { level in
                    bookRow(level, side: "Bid", tint: .positive, maxTotal: maxTotal)
                }

                ratioBar
            }
        }
        // Asks and bids are told apart by colour and position on screen; each row also says which it is (AI-10).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(bookSummary)
    }

    /// The book in words, in the app's language.
    private var bookSummary: String {
        guard let bid = book.bestBid, let ask = book.bestAsk else { return tr("Order book") }
        return tr("Order book. Best bid \(NumberStyle.number(bid)), best ask \(NumberStyle.number(ask)).")
    }

    private struct Level { let price: Double; let total: Double }

    /// Aggregates raw book levels into the current tick group (passthrough when grouping is 1×). Asks round up, bids
    /// round down, so every bucket stays on the correct side of the spread.
    private func aggregated(_ levels: [BookLevel], up: Bool) -> [(price: Double, size: Double)] {
        guard groupMultiplier > 1 else { return levels.map { (price: $0.price, size: $0.size) } }
        var buckets: [Double: Double] = [:]
        for l in levels {
            let key = (up ? (l.price / group).rounded(.up) : (l.price / group).rounded(.down)) * group
            buckets[key, default: 0] += l.size
        }
        return buckets.map { (price: $0.key, size: $0.value) }.sorted { up ? $0.price < $1.price : $0.price > $1.price }
    }

    private func cumulative(_ levels: [(price: Double, size: Double)]) -> [Level] {
        var running = 0.0
        return levels.map { running += $0.size; return Level(price: $0.price, total: running) }
    }

    private func bookRow(_ level: Level, side: LocalizedStringKey, tint: Color, maxTotal: Double) -> some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                Rectangle().fill(tint.opacity(0.16))
                    .frame(width: geo.size.width * min(1, level.total / maxTotal))
            }
            HStack {
                Text(NumberStyle.number(level.price)).font(.caption.monospacedDigit()).foregroundStyle(tint)
                Spacer(minLength: 4)
                Text(NumberStyle.number(level.total, compact: true)).font(.caption.monospacedDigit()).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 4)
        }
        .frame(height: wide ? 22 : 19)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(side)) \(NumberStyle.number(level.price)), total \(NumberStyle.number(level.total, compact: true)) \(symbol)"))
    }

    private var ratioBar: some View {
        let buy = book.bidShare
        return VStack(spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    Capsule().fill(Color.positive).frame(width: max(2, geo.size.width * buy - 1.5))
                    Capsule().fill(Color.negative)
                }
            }
            .frame(height: 4)
            HStack {
                Text(NumberStyle.percent(buy * 100, fractionDigits: 0, signed: false)).foregroundStyle(.positive)
                Spacer()
                Text(NumberStyle.percent((1 - buy) * 100, fractionDigits: 0, signed: false)).foregroundStyle(.negative)
            }
            .font(.caption2.weight(.medium)).monospacedDigit()
        }
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bids \(NumberStyle.percent(buy * 100, fractionDigits: 0, signed: false)) of visible depth, asks \(NumberStyle.percent((1 - buy) * 100, fractionDigits: 0, signed: false))")
    }
}

// MARK: - Percent-of-margin size slider

/// A track with five stops (0/25/50/75/100 %) and a draggable brand thumb, the size control from the reference perp
/// screens. Dragging fires a selection haptic when it crosses a stop and reports the live percentage so the ticket's
/// amount recalculates from available margin × leverage.
struct PercentSizeSlider: View {
    @Binding var percent: Double
    var onChange: (Double) -> Void
    @Environment(\.isEnabled) private var isEnabled

    private let stops = [0.0, 25, 50, 75, 100]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(Int(percent.rounded()))%")
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(percent > 0 ? Color.brand : Color.secondary)
            GeometryReader { geo in
                let w = geo.size.width
                let x = w * CGFloat(percent / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemFill)).frame(height: 3)
                    Capsule().fill(Color.brand).frame(width: max(0, x), height: 3)
                    ForEach(stops, id: \.self) { stop in
                        Circle()
                            .fill(percent >= stop - 0.01 ? Color.brand : Color(.systemBackground))
                            .overlay(Circle().stroke(percent >= stop - 0.01 ? Color.brand : Color(.systemFill), lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .position(x: w * CGFloat(stop / 100), y: geo.size.height / 2)
                    }
                    Circle().fill(Color.brand)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .frame(width: 18, height: 18)
                        .position(x: min(max(9, x), w - 9), y: geo.size.height / 2)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let pct = Double(min(max(0, value.location.x / w), 1)) * 100
                            let previousStop = nearestStop(percent)
                            percent = pct
                            if nearestStop(pct) != previousStop { Haptics.selection() }
                            onChange(pct)
                        }
                        .onEnded { _ in
                            // Snap to the nearest stop for a clean resting value.
                            let snapped = nearestStop(percent)
                            withAnimation(.easeOut(duration: 0.15)) { percent = snapped }
                            onChange(snapped)
                        }
                )
            }
            .frame(height: 22)
        }
        // One adjustable control for VoiceOver and Switch Control, in the 25% steps the track snaps to, instead of a
        // drag-only shape and a loose percentage text (security audit AI-4).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Size, share of available margin")
        .accessibilityValue("\(Int(percent.rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = 25.0
            let next: Double
            switch direction {
            case .increment: next = min(100, (percent / step).rounded(.down) * step + step)
            case .decrement: next = max(0, (percent / step).rounded(.up) * step - step)
            @unknown default: return
            }
            guard next != percent else { return }
            Haptics.selection()
            percent = next
            onChange(next)
        }
    }

    private func nearestStop(_ pct: Double) -> Double {
        stops.min(by: { abs($0 - pct) < abs($1 - pct) }) ?? 0
    }
}

// MARK: - Adjust Leverage sheet

/// A focused leverage picker: a ruler you drag, integer quick-picks, and a Confirm that applies the choice. The ruler
/// ticks a selection haptic at every whole leverage as you drag, and the value pill tracks your finger — the tactile
/// "changing leverage" feel of a native trading app.
struct LeverageSheet: View {
    let leverage: Double
    let maxLeverage: Double
    let onConfirm: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: Double

    init(leverage: Double, maxLeverage: Double, onConfirm: @escaping (Double) -> Void) {
        self.leverage = leverage
        self.maxLeverage = maxLeverage
        self.onConfirm = onConfirm
        _value = State(initialValue: leverage)
    }

    private var rounded: Double { value.rounded() }
    private var changed: Bool { Int(rounded) != Int(leverage.rounded()) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Adjust Leverage").font(.title2.weight(.bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close", comment: "Closes this screen or sheet (a verb)"))
            }
            .padding(.top, 22).padding(.horizontal, 22)

            LeverageRuler(value: $value, range: 1...max(2, maxLeverage))
                .frame(height: 104)
                .padding(.top, 28).padding(.horizontal, 20)
                .clipped()

            HStack(spacing: 12) {
                ForEach(quickPicks, id: \.self) { pick in
                    Button {
                        Haptics.selection()
                        withAnimation(.easeOut(duration: 0.2)) { value = Double(pick) }
                    } label: {
                        (pick == Int(maxLeverage) ? Text("Max", comment: "The most allowed: a button or chip that fills in the whole balance, or the highest leverage or amount [tight]") : Text(verbatim: "\(pick)x"))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Int(rounded) == pick ? Color.brand.opacity(0.15) : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(Int(rounded) == pick ? Color.brand : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pick == Int(maxLeverage) ? "Maximum leverage, \(pick) times" : "\(pick) times leverage")
                    .accessibilityAddTraits(Int(rounded) == pick ? .isSelected : [])
                }
            }
            .padding(.top, 30).padding(.horizontal, 20)

            Button {
                Haptics.commit(); onConfirm(rounded); dismiss()
            } label: {
                Text("Confirm")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 24).padding(.horizontal, 20)

            Spacer(minLength: 12)
        }
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
    }

    private var quickPicks: [Int] {
        [2, 5, 10, Int(maxLeverage)].filter { $0 <= Int(maxLeverage) }.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// A scrolling leverage ruler, the way the reference perp apps do it: a fixed brand indicator at the centre with the
/// current value pinned above and below it, while the whole tick strip + integer labels SLIDE horizontally under your
/// finger. You read the leverage where the ruler meets the centre line — the number stays put, the *ruler* moves.
struct LeverageRuler: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    /// Points per 1× — sets tick density and how many integers are visible at once (~7 across a phone width).
    private let pointsPerUnit: CGFloat = 50
    private let minorEvery = 0.2

    // Vertical layout. Each integer label morphs between the row baseline and the raised position as it nears the
    // centre: the nearest number rises to `topY` and enlarges to `bigSize` to BECOME the leverage value; the rest sit
    // small at `rowY`. There is no separate big readout — that was the duplicated number.
    private let topY: CGFloat = 15
    private let rowY: CGFloat = 47
    private let tickTop: CGFloat = 70
    private let majorTick: CGFloat = 24
    private let minorTick: CGFloat = 11
    private let rowSize: CGFloat = 15
    private let bigSize: CGFloat = 27

    private var lo: Double { range.lowerBound }
    private var hi: Double { range.upperBound }

    /// The leverage the current drag began at, so a finger translation maps to an absolute value.
    @State private var dragAnchor: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let center = w / 2
            let visibleUnits = Double(center / pointsPerUnit) + 1
            let firstInt = max(Int(lo.rounded(.up)), Int((value - visibleUnits).rounded(.down)))
            let lastInt = min(Int(hi.rounded(.down)), Int((value + visibleUnits).rounded(.up)))

            ZStack {
                // Tick strip — every tick is placed by its offset from the centred value, so the whole strip slides as
                // `value` changes. Whole numbers get a tall tick; sub-integer steps a short one.
                Canvas { ctx, size in
                    let ctr = size.width / 2
                    let half = Double(ctr / pointsPerUnit) + 1
                    var v = ((value - half) / minorEvery).rounded(.down) * minorEvery
                    let end = min(hi, value + half) + 0.0001
                    while v <= end {
                        if v >= lo - 0.0001 {
                            let x = ctr + CGFloat(v - value) * pointsPerUnit
                            let isWhole = abs(v.rounded() - v) < 0.001
                            let h = isWhole ? majorTick : minorTick
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: tickTop))
                            path.addLine(to: CGPoint(x: x, y: tickTop + h))
                            ctx.stroke(path, with: .color(Color(.tertiaryLabel).opacity(isWhole ? 0.85 : 0.4)), lineWidth: isWhole ? 1.4 : 1)
                        }
                        v += minorEvery
                    }
                }

                // Integer labels. Each stays at its own value-position (so the strip scrolls) while its size and height
                // interpolate by nearness to the centre: the closest number rises and grows to become the leverage
                // value, its neighbours shrink back into the row. One copy of each number — the raised one IS the value.
                if firstInt <= lastInt {
                    ForEach(firstInt...lastInt, id: \.self) { i in
                        let dist = abs(Double(i) - value)          // distance from the centred value, in leverage units
                        let p = max(0, 1 - dist)
                        let prox = p * p * (3 - 2 * p)              // smoothstep, so the nearest number pops cleanly
                        Text(verbatim: "\(i)X")
                            .font(.system(size: rowSize + (bigSize - rowSize) * prox, weight: prox > 0.55 ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary.opacity(0.4 + 0.6 * prox))
                            .fixedSize()
                            .position(x: center + CGFloat(Double(i) - value) * pointsPerUnit,
                                      y: rowY - (rowY - topY) * prox)
                    }
                }

                // Fixed centre — brand indicator line and the value pill (the precise, possibly-fractional value).
                Rectangle().fill(Color.brand).frame(width: 2.5, height: 70)
                    .position(x: center, y: 58)
                Text(verbatim: "\(NumberStyle.number(value, maximumFractionDigits: 1))x")
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.brand, in: Capsule())
                    .fixedSize()
                    .position(x: center, y: tickTop)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragAnchor == nil { dragAnchor = value }
                        let anchor = dragAnchor ?? value
                        let previous = Int(value.rounded())
                        // Scroll convention: dragging right pulls lower values to the centre (the strip follows the finger).
                        value = min(max(lo, anchor - Double(g.translation.width) / Double(pointsPerUnit)), hi)
                        if Int(value.rounded()) != previous { Haptics.selection() }
                    }
                    .onEnded { _ in
                        dragAnchor = nil
                        withAnimation(.easeOut(duration: 0.16)) { value = min(max(lo, value.rounded()), hi) }
                    }
            )
        }
        // The tick labels and value pill are one adjustable control: swipe up or down for 1× steps, so any leverage
        // can be chosen without dragging, not only the quick picks (security audit AI-4).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Leverage")
        .accessibilityValue("\(Int(value.rounded())) times")
        .accessibilityAdjustableAction { direction in
            let current = value.rounded()
            let next: Double
            switch direction {
            case .increment: next = min(hi, current + 1)
            case .decrement: next = max(lo, current - 1)
            @unknown default: return
            }
            guard next != value else { return }
            Haptics.selection()
            value = next
        }
    }
}

// MARK: - Order Type sheet

struct OrderTypeSheet: View {
    let kind: OrderKind
    let onSelect: (OrderKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Order Type") { dismiss() }
            VStack(spacing: 12) {
                optionRow(.market, icon: "bolt.fill", title: "Market", subtitle: "Execute immediately at current price")
                optionRow(.limit, icon: "chart.line.uptrend.xyaxis", title: "Limit", subtitle: "Set a specific price for your order")
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Spacer(minLength: 16)
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    private func optionRow(_ value: OrderKind, icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        let selected = kind == value
        return Button {
            Haptics.selection(); onSelect(value); dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(selected ? Color.brand : Color.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.headline.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .padding(14)
            .background(selected ? Color.brand.opacity(0.1) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Unit Preference sheet

struct UnitPreferenceSheet: View {
    let unit: OrderTicket.AmountUnit
    let asset: String
    let onSelect: (OrderTicket.AmountUnit) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Unit Preference") { dismiss() }
            VStack(spacing: 12) {
                optionRow(.asset, symbol: asset, title: asset, subtitle: "Order size is denominated in \(asset), the base asset.")
                optionRow(.usd, symbol: "AUSD", title: "AUSD", subtitle: "Order size is calculated from an AUSD amount at the current price.")
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Spacer(minLength: 16)
        }
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
    }

    /// `title` is the unit's symbol (the market's asset, or AUSD), shown as it is.
    private func optionRow(_ value: OrderTicket.AmountUnit, symbol: String, title: String, subtitle: LocalizedStringKey) -> some View {
        let selected = unit == value
        return Button {
            Haptics.selection(); onSelect(value); dismiss()
        } label: {
            HStack(spacing: 14) {
                MarketLogo(symbol: symbol, url: nil, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.headline.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .padding(14)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected ? Color.brand : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Price Type sheet

struct PriceTypeSheet: View {
    let selected: PerpTradeView.PriceType
    let onSelect: (PerpTradeView.PriceType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Price Type") { dismiss() }
            VStack(spacing: 12) {
                optionRow(.last, title: "Last Traded Price", subtitle: "Fill the limit price with the last trade.")
                optionRow(.mid, title: "Mid Price", subtitle: "Fill the limit price with the mid of the book.")
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Spacer(minLength: 16)
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    private func optionRow(_ value: PerpTradeView.PriceType, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        let isSel = selected == value
        return Button {
            Haptics.selection(); onSelect(value); dismiss()
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSel { Image(systemName: "checkmark").font(.headline.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .padding(14)
            .background(isSel ? Color.brand.opacity(0.1) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Select Perpetual sheet

struct SelectPerpetualSheet: View {
    let markets: [PerpMarket]
    let currentId: Int
    let change: (PerpMarket) -> Double?
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [PerpMarket] {
        guard !query.isEmpty else { return markets }
        let q = query.lowercased()
        return markets.filter { $0.asset.lowercased().contains(q) || $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Select Perpetual") { dismiss() }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search…", text: $query).autocorrectionDisabled().textInputAutocapitalization(.characters)
            }
            .font(.body)
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .padding(.horizontal, 20).padding(.top, 4)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { market in
                        Button {
                            Haptics.selection(); onSelect(market.id); dismiss()
                        } label: { marketRow(market) }
                        .buttonStyle(.plain)
                        if market.id != filtered.last?.id { Divider().padding(.leading, 64) }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 6)
            }
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
    }

    private func marketRow(_ market: PerpMarket) -> some View {
        let selected = market.id == currentId
        return HStack(spacing: 12) {
            MarketLogo(symbol: market.asset, url: nil, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(market.asset).font(.body.weight(.bold))
                Text(market.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(PriceFormat.usdPrice(market.mark))
                    .font(.body.weight(.semibold)).monospacedDigit()
                ChangeText(value: change(market), style: .caption)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(selected ? Color(.tertiarySystemFill) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Shared sheet header: a bold title on the left and a round close button on the right.
private func sheetHeader(_ title: LocalizedStringKey, onClose: @escaping () -> Void) -> some View {
    HStack {
        Text(title).font(.title2.weight(.bold))
        Spacer()
        Button(action: onClose) {
            Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close", comment: "Closes this screen or sheet (a verb)"))
    }
    .padding(.top, 20).padding(.horizontal, 20).padding(.bottom, 8)
}

// MARK: - Trades tape

struct TradesTape: View {
    let trades: [PerpTrade]
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Price").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Size (\(symbol))").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Time").font(.caption2).foregroundStyle(.secondary)
            }
            if trades.isEmpty {
                Text("Waiting for trades…").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                ForEach(trades.prefix(18)) { trade in
                    HStack {
                        Text(NumberStyle.number(trade.price)).font(.caption.monospacedDigit()).foregroundStyle(trade.side == .buy ? Color.positive : Color.negative)
                        Spacer()
                        Text(NumberStyle.number(trade.size, maximumFractionDigits: 4)).font(.caption.monospacedDigit())
                        Spacer()
                        Text(trade.time, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(height: 18)
                    // Buy or sell is shown by colour only; say it (AI-10).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tapeLabel(trade))
                }
            }
        }
    }
}

extension TradesTape {
    /// A trade in words, in the app's language: its side, size, price and time.
    fileprivate func tapeLabel(_ trade: PerpTrade) -> Text {
        let size = "\(NumberStyle.number(trade.size, maximumFractionDigits: 4)) \(symbol)"
        let price = NumberStyle.number(trade.price)
        let time = trade.time.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(L10n.locale))
        return trade.side == .buy ? Text("Buy \(size) at \(price), \(time)") : Text("Sell \(size) at \(price), \(time)")
    }
}

// MARK: - Position & order cards

struct PositionCard: View {
    let position: PerpPosition
    let liveMark: Double
    /// The TP/SL closing this position's side, as the Orders list shows them.
    var triggers: [TriggerRow] = []
    let onClose: () -> Void
    let onAddMargin: () -> Void
    let onTriggers: () -> Void

    private var livePnl: Double {
        let dir = position.side == .long ? 1.0 : -1.0
        return dir * (liveMark - position.entry) * position.size + position.premium
    }
    private var pnlPct: Double? { position.margin > 0 ? livePnl / position.margin * 100 : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PerpTradeView.sideLeverage(position)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(PriceFormat.usdValue(livePnl, signed: true))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    if let pnlPct {
                        Text(pnlPct, format: .number.precision(.fractionLength(2)).sign(strategy: .always())) + Text(verbatim: "%")
                    }
                }
                .foregroundStyle(livePnl < 0 ? Color.negative : Color.positive)
                .font(.caption.monospacedDigit())
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                stat("Size", "\(NumberStyle.number(position.size)) \(position.symbol)")
                stat("Entry", NumberStyle.number(position.entry))
                stat("Mark", NumberStyle.number(liveMark > 0 ? liveMark : position.mark))
                stat("Margin", PriceFormat.usdValue(position.margin))
                // An open position's liquidation price is nil only when its maintenance margin couldn't be read.
                stat("Liq.", position.liquidation.map { NumberStyle.number($0) } ?? PositionText.unknown)
                stat("Notional", PriceFormat.usdValue(position.notional))
            }
            if !triggers.isEmpty {
                Paragraph(triggerSummary).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Add Margin", action: onAddMargin)
                    .buttonStyle(.bordered).controlSize(.small).tint(.brand)
                Button("TP/SL", action: onTriggers)
                    .buttonStyle(.bordered).controlSize(.small).tint(.brand)
                    .accessibilityLabel("Take profit and stop loss")
                Button(action: onClose) { Text(verbatim: tr(LocalizedStringResource("position.close", defaultValue: "Close", comment: "Closes the open position (a verb), a button on the position. [tight]"))) }
                    .buttonStyle(.bordered).controlSize(.small).tint(.negative)
            }
        }
        .padding(.vertical, 4)
    }

    /// "TP 72,000 · SL 61,500", in the app's language.
    private var triggerSummary: String {
        let parts = triggers.map { PositionText.trigger($0.kind == .takeProfit, at: $0.price) }
        let verified = triggers.allSatisfy { $0.source == .live }
        let unverified = tr(LocalizedStringResource("unverified", comment: "Ends a TP/SL summary when Perpl's live list couldn't confirm it: “TP 72,000 · unverified”."))
        return (parts + (verified ? [] : [unverified])).joined(separator: " · ")
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
    }
}

/// A small labelled figure used across the order / trigger cards.
private struct MiniStat: View {
    let label: LocalizedStringKey
    let value: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(tint)
        }
    }
}

/// A resting on-chain order (limit / reduce-only limit), with its side, price, size, leverage and distance from mark —
/// "Cancelling…" instead of its Cancel while a cancel sent over the trading connection is on its way, and how it left
/// once Perpl's live list showed it gone (`gone`), with no Cancel then.
struct OrderCard: View {
    let order: PerpOrder
    let mark: Double
    var cancelling = false
    var gone: PerplTrading.ChainOrderGone? = nil
    let onCancel: () -> Void

    private var typeLabel: String {
        order.reduceOnly ? tr("Limit · reduce-only")
            : tr(LocalizedStringResource("Limit", comment: "Order type: rests at the price you set until it fills. [tight]"))
    }
    private var distance: Double? { mark > 0 ? (order.price - mark) / mark * 100 : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(order.side == .buy ? "Buy" : "Sell")
                    .font(.caption.weight(.bold)).foregroundStyle(Color.onStatus)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(order.side == .buy ? Color.positive : Color.negative, in: Capsule())
                Text(typeLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let gone {
                    // A cancel from this device: what became of it ("Filled first"). Otherwise the order left on its own.
                    Text(verbatim: gone.byCancel ? PerpActionCopy.orderState(gone.result) : PerpActionCopy.orderLeft(gone.result))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                } else if cancelling {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(verbatim: PerpTriggerCopy.rowCancelling)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Cancel", action: onCancel).buttonStyle(.bordered).controlSize(.small).tint(.negative)
                }
            }
            HStack(alignment: .top) {
                MiniStat(label: "Price", value: NumberStyle.number(order.price))
                Spacer()
                MiniStat(label: "Size", value: "\(NumberStyle.number(order.size)) \(order.symbol)")
                Spacer()
                MiniStat(label: "Leverage", value: "\(NumberStyle.number(order.leverage, maximumFractionDigits: 1))×")
                Spacer()
                if let d = distance { MiniStat(label: "Distance", value: String(format: "%+.2f%%", d), tint: d >= 0 ? .positive : .negative) }
            }
        }
        .opacity(cancelling || gone != nil ? 0.6 : 1)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A TP/SL row to display: Perpl's open trigger from the trading stream (live, or the last list it sent before it
/// went offline), or the app's own record of one it placed (just placed, or unverifiable while offline).
struct TriggerRow: Identifiable {
    enum Source: Equatable {
        /// On Perpl's live list: authoritative, and cancellable from here.
        case live
        /// On the last list Perpl sent; the stream is offline, so it may have fired or been cancelled since.
        case lastKnown
        /// Just placed from this device; the stream hasn't shown it yet.
        case pending
        /// This device's record while the stream is offline: never confirmed against Perpl.
        case unverified
    }
    let id: String
    let symbol: String
    let kind: PlacedTrigger.Kind
    let price: Double
    let size: Double
    let positionLong: Bool
    let source: Source
    /// The trigger on Perpl, for a row from its list.
    let order: PerplOpenOrder?
    /// The size of the open position on the side this trigger closes, if there is one.
    let positionSize: Double?

    /// Where the row comes from, in the app's language.
    var label: String {
        switch source {
        case .live: return tr("Keeper trigger")
        case .lastKnown: return tr("Last seen on Perpl")
        case .pending: return tr("Pending…")
        case .unverified: return tr("Saved on this device · unverified")
        }
    }

    /// How much of the position it closes, when that isn't all of it (security audit GT-5: a trigger's size is fixed
    /// when it's placed and doesn't follow the position).
    var coverage: String? {
        guard let positionSize, positionSize > 0, size > 0 else { return nil }
        let tolerance = max(positionSize, size) * 1e-6
        let held = "\(NumberStyle.number(positionSize)) \(symbol)"
        if size < positionSize - tolerance { return tr("Closes \(NumberStyle.number(size)) of your \(held)") }
        if size > positionSize + tolerance { return tr("Larger than your \(held) position") }
        return nil
    }
}

/// A take-profit / stop-loss (keeper-managed trigger), labelled by where it comes from, with a Cancel for a live one —
/// dimmed and "Cancelling…" instead while a cancel sent for it is on its way (a second tap would send a second).
struct TriggerCard: View {
    let row: TriggerRow
    let mark: Double
    var cancelling = false
    var onCancel: () -> Void = {}

    private var tint: Color { row.kind == .takeProfit ? .positive : .negative }
    private var distance: Double? { mark > 0 ? (row.price - mark) / mark * 100 : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: row.kind == .takeProfit ? "target" : "shield.lefthalf.filled")
                    .font(.caption).foregroundStyle(tint)
                Text(row.kind.label).font(.caption.weight(.bold)).foregroundStyle(tint)
                Text(row.positionLong ? "on Long" : "on Short").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if row.source == .live, row.order != nil, cancelling {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(verbatim: PerpTriggerCopy.rowCancelling)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                } else if row.source == .live, row.order != nil {
                    Button("Cancel", action: onCancel).buttonStyle(.bordered).controlSize(.small).tint(.negative)
                        .accessibilityLabel(row.kind == .takeProfit ? "Cancel take profit at \(NumberStyle.number(row.price))" : "Cancel stop loss at \(NumberStyle.number(row.price))")
                } else {
                    Text(row.label).font(.caption2).foregroundStyle(row.source == .live || row.source == .pending ? Color.secondary : Color.attention)
                }
            }
            HStack(alignment: .top) {
                MiniStat(label: "Trigger", value: NumberStyle.number(row.price), tint: tint)
                Spacer()
                MiniStat(label: "Size", value: "\(NumberStyle.number(row.size)) \(row.symbol)")
                Spacer()
                if let d = distance { MiniStat(label: "Distance", value: String(format: "%+.2f%%", d)) }
            }
            if let coverage = row.coverage {
                Text(coverage).font(.caption2).foregroundStyle(Color.attention)
            }
        }
        .opacity(cancelling ? 0.6 : 1)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(row.source == .live ? 0.22 : 0.12), lineWidth: 1))
    }
}

/// Which triggers a Cancel sheet is for, and the sheet's title and note, written where the request is made.
struct TriggerCancelRequest: Identifiable {
    let id = UUID()
    let orders: [PerplOpenOrder]
    let title: LocalizedStringResource
    let note: LocalizedStringResource?
}

/// Closes a position at market or with a resting reduce-only limit order (optionally post-only), all of it or 25 / 50 /
/// 75%. Sent as a wallet transaction, what it did is read from its receipt once it confirms — closed in full or in part,
/// resting on the book, or nothing filled — and said before Done (the transaction alone only says it ran: a market close
/// with nothing within its slippage confirms too). With one-click live for the account at the tap (`route`), it goes to
/// Perpl over the trading connection instead and its result is followed on Perpl's stream (p4 spec A.4.1): the same words,
/// as they happen, whether the sheet stays open or not.
struct ClosePositionSheet: View {
    let market: PerpMarket
    let position: PerpPosition
    let mark: Double
    /// The Perpl account the close is sent for: its own request is read from the receipt.
    var accountId: Int?
    /// The live TP/SL closing this position's side, to say what happens to them (security audit GT-2).
    var leftoverTriggers: [PerplOpenOrder] = []
    /// The trading connection's route for this close, fixed at the tap that opened the sheet; nil: the wallet transaction.
    var route: PerplTrading.ActionAccount? = nil
    /// The close is about to be sent (`whole`: the 100% chip), and — if it then fails before anything left the device, or
    /// it filled nothing — it didn't close: so the positions poll knows the position's disappearance is expected from the
    /// moment it could happen (GT-9), not only once Done is tapped, and is news again when nothing closed. A partial close
    /// never notes a close of the position.
    var onSending: (_ whole: Bool) -> Void = { _ in }
    var onNotSent: () -> Void = {}
    /// The close's result was read: the caller reads the position again at once.
    var onSettled: () -> Void = {}
    /// The caller's reload, on Done.
    let onDone: () -> Void

    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(\.dismiss) private var dismiss
    @State private var run = TransactionRun()
    @State private var kind: OrderKind = .market
    @State private var limitText = ""
    @State private var postOnly = false
    /// The size chip: 25, 50, 75 or 100 (% of the position as the chain reports it).
    @State private var percent = 100
    /// The desc id the plan sent signs (what finds the close in its receipt), fixed at the tap.
    @State private var sentDescId: UInt64?
    /// What the close did, once read from its receipt; nil while it is read.
    @State private var settled: PerplOutcomeText?
    /// The receipt is being read now, and Done is held for the first moments of it (`ReceiptResultBar.doneHold`).
    @State private var reading = false
    @State private var holdingDone = false
    /// The trading connection's close (`route`): where it is, from the confirm to Perpl's result.
    @State private var apiPhase: APIPhase = .review
    /// The one line under a not-sent failure (nil: refused on the device).
    @State private var failureLine: String?
    /// When the close started waiting for Perpl (the "you can close this" line shows after 3 s).
    @State private var waitingSince: Date?
    /// The result headline VoiceOver last announced.
    @State private var announcedHeadline: String?
    #if DEBUG && targetEnvironment(simulator)
    @Environment(\.perpsDemoAutoConfirm) private var demoAutoConfirm
    @Environment(\.perpsDemoTerms) private var demoTerms
    @Environment(\.perpsDemoTryAgain) private var demoTryAgain
    #endif

    enum APIPhase: Equatable {
        case review, authorizing, sending, tracking(UUID), failed(String)
        var isFailed: Bool { if case .failed = self { return true }; return false }
    }

    private var isLimit: Bool { kind == .limit }
    private var limitPrice: Double? { limitText.perpDouble }
    /// A limit close far through the mark would fill at once (a decimal slip): refused, as on the order ticket. The
    /// close trades the opposite side of the position.
    private var limitProblem: String? {
        guard isLimit, let limitPrice, limitPrice > 0 else { return nil }
        if let offTick = OrderTicket.offTickProblem(price: limitPrice, market: market) { return offTick }
        return OrderTicket.throughMarkProblem(price: limitPrice, side: position.side == .long ? .short : .long, mark: mark, market: market)
    }
    /// The size the chip closes, at the market's lot precision (nil: less than one lot).
    private func chipSize(_ percent: Int) -> Double? {
        PerplService.closeFractionSize(positionSize: position.size, lotDecimals: market.lotDecimals, percent: percent)
    }
    private var sentSize: Double { chipSize(percent) ?? position.size }
    private var canConfirm: Bool { session.canSign && !run.isRunning && (!isLimit || (limitPrice ?? 0) > 0) && limitProblem == nil && chipSize(percent) != nil }

    private var steps: [TransactionStep] {
        env.perpl.closePositionPlan(market: market, position: position, slippageBps: Self.slippageBps, kind: kind, limitPrice: limitPrice, postOnly: postOnly, size: sentSize)
    }

    /// The close this sheet follows over the trading connection.
    private var tracked: PerplTrackedOrder? {
        if case .tracking(let id) = apiPhase { return perplTrading.orders.order(id) }
        return nil
    }
    private var isTracking: Bool { if case .tracking = apiPhase { return true }; return false }
    /// Perpl's final word that the close executed nothing: Try Again, with the terms editable again.
    private var executedNothing: Bool { tracked?.entry?.executedNothing == true }
    /// Perpl refused the close because order forwarding is off (OrderForwardingNotAllowed, sr 34): the trading route rests,
    /// so no Try Again here — the reopened sheet sends it from the wallet, and the sheet says so.
    private var refusedForForwarding: Bool {
        if case .failed(let reason)? = tracked?.entry { return reason.reason == 34 }
        return false
    }
    /// The result is in and isn't "not confirmed": Done, not Close.
    private var isDecided: Bool { tracked?.entry.map { !PerplTracker.isUnconfirmed($0) } ?? false }
    /// The terms can't change: a close is being confirmed, sent or followed (until Perpl says it executed nothing), or the
    /// wallet's is signing or done.
    private var termsLocked: Bool {
        switch apiPhase {
        case .authorizing, .sending: return true
        case .tracking: return !executedNothing || refusedForForwarding
        case .review, .failed: return run.isRunning || run.isDone || run.sentSomething
        }
    }
    /// The close's result in words, a close Perpl never answered saying it may have gone through.
    private func closeText(_ order: PerplTrackedOrder, _ entry: PerplOrderOutcome) -> PerplOutcomeText {
        let words = PerplOutcomeText.close(entry, order.textContext)
        guard PerplTracker.isUnconfirmed(entry), !order.acknowledged else { return words }
        return PerplOutcomeText(headline: words.headline, detail: PerpActionCopy.closeUnknown, tone: words.tone)
    }
    private var trackedHeadline: String? {
        guard let order = tracked, let entry = order.entry else { return nil }
        return PerplOutcomeText.close(entry, order.textContext).headline
    }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow("Position", verbatim: PositionText.amount(isLong: position.side == .long, size: position.size, asset: position.symbol), tint: position.side == .long ? .positive : .negative)
                    DetailRow("Mark price", NumberStyle.number(mark))
                    DetailRow("Unrealized", PriceFormat.usdValue(position.unrealized, signed: true), tint: position.unrealized < 0 ? .negative : .positive)
                }
                Section {
                    Picker("Type", selection: $kind) {
                        Text("Market", comment: "Order type: a market order, which fills at once at the market price. [tight]").tag(OrderKind.market)
                        Text("Limit", comment: "Order type: rests at the price you set until it fills. [tight]").tag(OrderKind.limit)
                    }
                    .pickerStyle(.segmented)
                    .disabled(termsLocked)
                    HStack(spacing: 8) {
                        ForEach([25, 50, 75, 100], id: \.self) { chip in
                            Button { percent = chip } label: { Text(verbatim: "\(chip)%") }
                                .buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
                                .tint(percent == chip ? Color.brand : Color.secondary)
                                .disabled(termsLocked || chipSize(chip) == nil)
                                .accessibilityAddTraits(percent == chip ? .isSelected : [])
                        }
                    }
                    DetailRow("Size", verbatim: PositionText.amount(isLong: position.side == .long, size: sentSize, asset: position.symbol))
                    if isLimit {
                        HStack {
                            Text("Limit price").foregroundStyle(.secondary)
                            Spacer()
                            TextField(NumberStyle.number(mark), text: $limitText)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                                .disabled(termsLocked)
                        }
                        // The price this close signs, read back from the typed text (audit F4).
                        if let limitPrice, limitPrice > 0 { DetailRow("Limit at", NumberStyle.number(limitPrice, maximumFractionDigits: market.priceDecimals)) }
                        if let limitProblem { Paragraph(limitProblem).font(.footnote).foregroundStyle(Color.attention) }
                        Toggle("Post only (maker)", isOn: $postOnly).disabled(termsLocked)
                        Paragraph("Rests as a reduce-only limit at your price until it fills. It won't reduce your position until then.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DetailRow("Order", "Market, reduce-only, 1% slippage")
                    }
                } header: {
                    Text("Close order")
                } footer: {
                    if route != nil { Paragraph("Signed and forwarded by your Perpl API key over the trading connection.") }
                }
                if !leftoverTriggers.isEmpty {
                    Section("Take-profit / stop-loss") {
                        leftoverNote(count: leftoverTriggers.count)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !run.events.isEmpty { Section("Progress") { TransactionProgress(events: run.events, neutralConfirmation: true) } }
                if let settled { PerpOrderOutcomeSection(text: settled) }
                if case .failed(let message) = run.phase {
                    Section { InlineError(message: message) }.listRowBackground(Color.clear)
                }
                if let order = tracked, let entry = order.entry {
                    PerpOrderOutcomeSection(text: closeText(order, entry))
                }
                if case .failed(let message) = apiPhase {
                    Section {
                        InlineError(message: message)
                        if let failureLine { Paragraph(verbatim: failureLine).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Close Position"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isTracking {
                        Button(isDecided ? "Done" : "Close") { finish() }
                    } else {
                        Button(run.isDone ? "Done" : "Cancel") { finish() }.disabled(run.isRunning || holdingDone || apiPhase == .authorizing || apiPhase == .sending)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let route {
                        apiBar(route)
                    } else if run.isDone {
                        // What the close did, read from its receipt (Done held for the first moments of the read).
                        ReceiptResultBar(settled: settled, reading: reading, holdingDone: holdingDone) { finish() }
                    } else if case .failed = run.phase, run.sentSomething {
                        // Already on the network: no re-confirm (it would replay the plan), as in ConfirmationSheet.
                        Text(TransactionRun.alreadySent).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                    } else if !session.canSign {
                        Paragraph(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        // A passkey account's close always asks (MERA-PLAN §3): one Face ID when it's signed.
                        if session.isPasskeyAccount { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.closePosition.summary)) }
                        PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : (isLimit ? "Place Limit Close" : "Close at Market"), isBusy: run.isRunning, isDisabled: !canConfirm) {
                            Task {
                                if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm close")) { return }
                                onSending(percent == 100)
                                // The plan built once: the desc id read back from its receipt is the one it signs.
                                let plan = steps
                                sentDescId = PerplReceipt.descId(ofPlan: plan)
                                run.start(plan, session: session, sender: env.sender, action: session.isPasskeyAccount ? MeraSession.Action(.alwaysAsks(.closePosition)) : nil)
                            }
                        }
                    }
                }
                .padding().frame(maxWidth: .infinity).background(.bar)
            }
            .interactiveDismissDisabled(run.isRunning || holdingDone || apiPhase == .sending || apiPhase == .authorizing)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        // The result's tone, once read: a full close is a success, a partial one or nothing closed is not.
        .sensoryFeedback(trigger: settled?.tone) { _, tone in tone.flatMap(PerpOutcomeTone.feedback) }
        .sensoryFeedback(trigger: tracked?.entry?.tone) { _, tone in tone.flatMap(PerpOutcomeTone.feedback) }
        // Recorded when the close settles, not when the sheet is dismissed: a settled sheet can be swiped away.
        .onChange(of: run.phase) { _, phase in
            switch phase {
            case .done(let hash):
                onSending(percent == 100) // settled: expected from now on, whenever the poll next reads
                // At the receipt (GL-3): the close was sent and its result isn't read yet. No volume until a fill is read.
                Activity.record(ActivityRecord(kind: .perp, title: PerpOnChainCopy.closeTitle(position.symbol), subtitle: PerpOnChainCopy.closeSent, hash: hash,
                                               section: "perps", usd: nil), owner: session.address, notify: false)
                readResult(hash)
            case .failed where !run.sentSomething:
                onNotSent()
            case .idle, .running, .failed:
                break
            }
        }
        // The close over the trading connection: its result as Perpl reports it — the positions are read again, a close
        // that executed nothing is news again — and every new headline is announced.
        .onChange(of: tracked?.entry) { _, entry in
            guard let entry, !PerplTracker.isUnconfirmed(entry) else { return }
            onSettled()
            if entry.executedNothing { onNotSent() }
        }
        .onChange(of: trackedHeadline) { _, headline in
            guard let headline, headline != announcedHeadline else { return }
            announcedHeadline = headline
            AccessibilityNotification.Announcement(headline).post()
        }
        .onDisappear {
            if case .tracking(let id) = apiPhase { perplTrading.orders.setPresented(id, false) }
        }
        #if DEBUG && targetEnvironment(simulator)
        // The scripted Perps demo only (`PerpsDemo`): its terms, and with Run this sheet's own confirm 2 s after it appears
        // (App Lock still asks); its Try Again when the script says.
        .task {
            guard perplTrading.isDemo else { return }
            if let demoTerms {
                percent = demoTerms.percent
                kind = demoTerms.limitText == nil ? .market : .limit
                limitText = demoTerms.limitText ?? ""
                postOnly = demoTerms.postOnly
            }
            guard let demoAutoConfirm, let route else { return }
            try? await Task.sleep(for: demoAutoConfirm)
            confirmAPI(route)
        }
        .onChange(of: demoTryAgain) { _, _ in
            if perplTrading.isDemo, let route { tryAgain(route) }
        }
        #endif
    }

    /// Where the close button was, on the trading connection's path: the button (again after a failure before anything
    /// was sent), "Sending to Perpl…", then the live status — waiting, its result with Done (and Try Again when Perpl
    /// said it executed nothing), or "not confirmed" with Close.
    @ViewBuilder private func apiBar(_ route: PerplTrading.ActionAccount) -> some View {
        switch apiPhase {
        case .review, .failed, .authorizing:
            if !session.canSign {
                Paragraph(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                if session.isPasskeyAccount { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.closePosition.summary)) }
                PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : (isLimit ? "Place Limit Close" : "Close at Market"),
                              isBusy: apiPhase == .authorizing, isDisabled: !canConfirm) {
                    confirmAPI(route)
                }
            }
        case .sending:
            HStack(spacing: 10) {
                ProgressView()
                Paragraph(verbatim: PerpOrderCopy.sending).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tracking:
            if let order = tracked {
                if let entry = order.entry, !PerplTracker.isUnconfirmed(entry) {
                    VStack(spacing: 8) {
                        PerpOrderStatusBar(text: closeText(order, entry))
                        if refusedForForwarding {
                            // One-click is off on Perpl: this route can't take it, the wallet's can.
                            Paragraph(verbatim: perplTrading.nothingSentLine(for: route)).font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                        } else if entry.executedNothing {
                            // Perpl's final word: nothing executed, so a new close can't double it (GL-1).
                            PrimaryButton(title: "Try Again", systemImage: "arrow.clockwise", isDisabled: !canConfirm) { tryAgain(route) }
                            Button("Done") { finish() }.font(.subheadline.weight(.semibold))
                        } else {
                            PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                        }
                    }
                } else if let entry = order.entry {
                    VStack(spacing: 8) {
                        PerpOrderStatusBar(text: closeText(order, entry))
                        PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 8) {
                            HStack(spacing: 10) {
                                ProgressView()
                                Paragraph(verbatim: order.acknowledged ? PerpOrderCopy.waiting : PerpOrderCopy.stillListening).font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let waitingSince, context.date.timeIntervalSince(waitingSince) >= 3 {
                                Paragraph(verbatim: PerpOrderCopy.canClose(market: "\(market.asset)-PERP")).font(.footnote).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                        }
                    }
                }
            }
        }
    }

    /// The confirm on the trading connection (A.3.1): ignored unless nothing is under way, and busy at once, before the
    /// App Lock prompt — a double tap can never start a second close.
    private func confirmAPI(_ route: PerplTrading.ActionAccount) {
        guard apiPhase == .review || apiPhase.isFailed else { return }
        apiPhase = .authorizing
        failureLine = nil
        Task { await closeOverAPI(route) }
    }

    /// Try Again after Perpl's final word that the close executed nothing: its result is marked seen (no status row for
    /// it), then a new confirm — App Lock, a passkey account's new step-up, a new request.
    private func tryAgain(_ route: PerplTrading.ActionAccount) {
        guard case .tracking(let old) = apiPhase, executedNothing, !refusedForForwarding else { return }
        perplTrading.orders.setPresented(old, false)
        perplTrading.orders.dismissBanner(old)
        apiPhase = .review
        confirmAPI(route)
    }

    /// The close over the trading connection: App Lock (as the wallet's close asks it), then the passkey session held for
    /// the send (GL-1), then `submitClose` — a passkey account's close always asks first (MERA-PLAN §3) — and Perpl's
    /// result followed (`track`, whether this sheet stays open or not). Nothing is ever resent from here.
    private func closeOverAPI(_ route: PerplTrading.ActionAccount, approval: MeraSession.StepUp? = nil) async {
        if approval == nil, settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm close")) {
            onNotSent()
            apiPhase = .review
            return
        }
        // A passkey session (and its trading socket) outlives leaving the app until this close is sent (GL-1).
        session.mera.beginAction()
        defer { session.mera.endAction() }
        apiPhase = .sending
        let request = PerplTrading.CloseRequest(market: market, position: position, percent: percent, kind: kind, limitPrice: isLimit ? limitPrice : nil,
                                                postOnly: isLimit && postOnly)
        let whole = percent == 100
        let expectation = perplTrading.expectOrder(PerplService.closeInput(market: market, position: position, size: sentSize, slippageBps: Self.slippageBps),
                                                   held: (position.side, position.size))
        var followed = false
        defer { if !followed { perplTrading.releaseOrderExpectation(expectation) } }
        do {
            let (result, sent) = try await perplTrading.submitClose(request, account: route, env: env, approval: approval, onWriting: { whole in onSending(whole) })
            guard result.entry, let tracking = result.tracking else {
                // Perpl's gateway refused it: nothing was forwarded.
                onNotSent()
                failureLine = perplTrading.nothingSentLine(for: route)
                apiPhase = .failed(result.error ?? tr("Perpl rejected the order."))
                return
            }
            let id = perplTrading.track(tracking, input: sent, takeProfit: nil, stopLoss: nil, closes: position.side, held: (position.side, position.size), ttlBlocks: 100,
                                        before: position, beforeReadAt: nil, restingOnSide: false, expectation: expectation, purpose: .close(wholePosition: whole))
            followed = true
            perplTrading.orders.setPresented(id, true)
            waitingSince = Date()
            apiPhase = .tracking(id)
        } catch is MeraSession.StepUpRequired where approval == nil {
            // MERA-PLAN §3: one pinned passkey ceremony approves this close, then it is sent.
            do {
                let approval = try await session.mera.stepUp()
                await closeOverAPI(route, approval: approval)
            } catch where isUserCancellation(error) {
                onNotSent()
                failureLine = perplTrading.nothingSentLine(for: route)
                apiPhase = .failed(TransactionRun.notSent)
            } catch {
                onNotSent()
                failureLine = perplTrading.nothingSentLine(for: route)
                apiPhase = .failed(describe(error))
            }
        } catch let unanswered as PerplTrading.EntryUnanswered {
            // Written and never answered: it may have gone through. Followed like any order (I7), never resent.
            let id = perplTrading.track(unanswered.tracking, input: unanswered.input, takeProfit: nil, stopLoss: nil, closes: position.side,
                                        held: (position.side, position.size), ttlBlocks: 100, before: position, beforeReadAt: nil, restingOnSide: false,
                                        expectation: expectation, purpose: .close(wholePosition: whole))
            followed = true
            perplTrading.orders.setPresented(id, true)
            waitingSince = Date()
            apiPhase = .tracking(id)
        } catch {
            onNotSent()
            // Refused on the device: the message says why, and nothing else needs saying.
            failureLine = (error as? PerplTradeError)?.isInvalidOrder == true ? nil : perplTrading.nothingSentLine(for: route)
            apiPhase = .failed(describe(error))
        }
    }

    /// What the close says of the position, from what it was sent as.
    private var closeContext: PerplOutcomeText.Context {
        PerplOutcomeText.Context(asset: market.asset, priceDecimals: market.priceDecimals, lotDecimals: market.lotDecimals,
                                 requestedSize: sentSize, limitPrice: isLimit ? limitPrice : nil, isMarket: !isLimit, reducesPosition: true,
                                 slippageBps: Self.slippageBps, acknowledged: false)
    }

    /// The market close's slippage (`closePositionPlan`).
    private static let slippageBps = PerplTrading.CloseRequest.slippageBps

    /// Reads the close's receipt in a task of its own (a dismissed sheet still upgrades its row), and records what it did:
    /// closed or partly closed with the volume that filled at the price it filled at, a close resting on the book (no
    /// volume), or nothing filled (the close noted when it was sent is voided). A receipt that can't be read keeps the
    /// row it was sent with. One notice, with the result.
    private func readResult(_ hash: Data) {
        reading = true
        holdingDone = true
        Task { @MainActor in
            try? await Task.sleep(for: ReceiptResultBar.doneHold)
            holdingDone = false
        }
        let owner = session.address
        let symbol = position.symbol
        let context = closeContext
        let ordered = PositionText.amount(isLong: position.side == .long, size: sentSize, asset: position.symbol)
        let partOnly = percent < 100
        let accountId = accountId
        let descId = sentDescId
        let perpl = env.perpl
        Task { @MainActor in
            let background = BackgroundTime("Perpl result") // not localized: the background task's name, never shown
            defer { background.end() }
            let requests = try? await perpl.receiptRequests(hash)
            let outcome = accountId.flatMap { PerplReceipt.orderOutcome(requests, accountId: $0, descId: descId.map { BigUInt($0) }) }
            let row: ActivityRecord
            switch outcome {
            case .filled(let fill)?, .partlyFilled(let fill, _)?:
                let closed = PerplOutcomeText.amount(fill.size(lotDecimals: context.lotDecimals), context)
                let partly: Bool = { if case .partlyFilled? = outcome { return true }; return false }()
                let subtitle: String
                if let price = fill.price(priceDecimals: context.priceDecimals), price > 0 {
                    let at = NumberStyle.number(price, maximumFractionDigits: context.priceDecimals)
                    subtitle = partly
                        ? PerpOnChainCopy.partlyClosedAt(closed, of: PerplOutcomeText.amount(Double(fill.requestedSizeRaw) / pow(10, Double(context.lotDecimals)), context), price: at)
                        : PerpOnChainCopy.closedAt(closed, price: at)
                } else {
                    subtitle = closed
                }
                // Partly closed when the receipt says so, or the chip closed only part of the position.
                row = ActivityRecord(kind: .perp, title: partly || partOnly ? PerpOnChainCopy.partlyClosedTitle(symbol) : tr("Closed \(symbol)"), subtitle: subtitle, hash: hash, section: "perps",
                                     usd: outcome?.volumeUSD(priceDecimals: context.priceDecimals, lotDecimals: context.lotDecimals),
                                     feeUsd: fill.feeUSD.flatMap { $0 > 0 ? $0 : nil })
            case .resting?:
                let limit = tr(LocalizedStringResource("Limit", comment: "Order type: rests at the price you set until it fills. [tight]"))
                row = ActivityRecord(kind: .perp, title: tr("Close order placed"), subtitle: "\(ordered) · \(limit)", hash: hash, section: "perps", usd: nil)
            case let decided? where decided.executedNothing:
                // Nothing closed: the position's ending is news again, and the row says the transaction filled nothing.
                onNotSent()
                PendingActivity.notFilled(hash, owner: owner)
                row = ActivityRecord(kind: .perp, title: PerpOnChainCopy.closeTitle(symbol), subtitle: PerpOnChainCopy.nothingFilled, hash: hash, section: "perps", usd: nil)
            default:
                // Couldn't be read: the row it was sent with stays, said once.
                row = ActivityRecord(kind: .perp, title: PerpOnChainCopy.closeTitle(symbol), subtitle: PerpOnChainCopy.closeSent, hash: hash, section: "perps", usd: nil)
            }
            Activity.record(row, owner: owner)
            settled = outcome.map { PerplOutcomeText.close($0, context) }
                ?? PerplOutcomeText(headline: PerpOnChainCopy.unreadable, detail: nil, tone: .warning)
            reading = false
            holdingDone = false
            onSettled()
            if let settled { AccessibilityNotification.Announcement(settled.headline).post() }
        }
    }

    /// What happens to the position's TP/SL once it is closed, for its side and the kind of account. The count is a
    /// plural.
    @ViewBuilder private func leftoverNote(count: Int) -> some View {
        switch (session.isPasskeyAccount, position.side == .long) {
        case (true, true):
            Paragraph("This position has \(count) TP/SL on Perpl. Once it is fully closed, cancel them from Orders (they would otherwise stay armed for your next long here).")
        case (true, false):
            Paragraph("This position has \(count) TP/SL on Perpl. Once it is fully closed, cancel them from Orders (they would otherwise stay armed for your next short here).")
        case (false, true):
            Paragraph("This position has \(count) TP/SL on Perpl. Once it is fully closed, the app cancels them while Perpl trading is connected, so they can't fire on your next long here. Check Orders afterwards.")
        case (false, false):
            Paragraph("This position has \(count) TP/SL on Perpl. Once it is fully closed, the app cancels them while Perpl trading is connected, so they can't fire on your next short here. Check Orders afterwards.")
        }
    }

    private func finish() {
        // Done after a result (the wallet's or Perpl's): the screen behind reads the position again.
        let done = run.isDone || isTracking
        dismiss()
        if done { onDone() }
    }
}

/// Adds AUSD collateral to an open position — lowering its leverage and pushing the liquidation price away. Sent as a
/// wallet transaction, the margin the position received is read from the receipt once it confirms, and said before Done.
/// With one-click live for the account at the tap (`route`), it goes to Perpl over the trading connection instead, and
/// its result is Perpl's evidence (p4 spec A.4.3): added, refused, or not confirmed in time — said in the sheet while it
/// is open, else as a notification, and in Activity either way.
struct AddMarginSheet: View {
    let market: PerpMarket
    let position: PerpPosition
    let available: Double
    /// The Perpl account the margin is added for: its own request is read from the receipt.
    var accountId: Int?
    /// The trading connection's route for this margin, fixed at the tap that opened the sheet; nil: the wallet transaction.
    var route: PerplTrading.ActionAccount? = nil
    /// The margin's result was read: the caller reads the position again at once.
    var onSettled: () -> Void = {}
    let onDone: () -> Void

    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(\.dismiss) private var dismiss
    @State private var run = TransactionRun()
    @State private var amountText = ""
    /// The desc id the plan sent signs (what finds it in its receipt), fixed at the tap.
    @State private var sentDescId: UInt64?
    /// What the transaction did, once read from its receipt; nil while it is read.
    @State private var settled: PerplOutcomeText?
    /// The receipt is being read now, and Done is held for the first moments of it (`ReceiptResultBar.doneHold`).
    @State private var reading = false
    @State private var holdingDone = false
    /// The trading connection's margin (`route`): where it is, from the confirm to Perpl's evidence.
    @State private var apiPhase: APIPhase = .review
    /// The request's row id once it was written (its result, live, is `PerplTrading.marginResults[id]`).
    @State private var marginId: UUID?
    /// This market's position read when the sheet opened, and when: the margin's "before" (else the position tapped).
    @State private var freshBefore: PerpPosition?
    @State private var freshBeforeAt: Date?
    /// The one line under a not-sent failure (nil: refused on the device).
    @State private var failureLine: String?
    @State private var announcedHeadline: String?
    #if DEBUG && targetEnvironment(simulator)
    @Environment(\.perpsDemoAutoConfirm) private var demoAutoConfirm
    @Environment(\.perpsDemoTerms) private var demoTerms
    #endif

    enum APIPhase: Equatable {
        case review, authorizing, sending
        case waiting(id: UUID, since: Date, acknowledged: Bool)
        case settled(PerplTrading.MarginResult)
        case failed(String)
        var isFailed: Bool { if case .failed = self { return true }; return false }
    }

    private var amount: Double { amountText.perpDouble ?? 0 }
    private var overBalance: Bool { amount > available + 0.000001 }
    private var canConfirm: Bool { session.canSign && !run.isRunning && amount > 0 && !overBalance }

    private var projMargin: Double { position.margin + max(0, amount) }
    private var projLeverage: Double { projMargin > 0 ? position.notional / projMargin : position.leverage }
    private var projLiquidation: Double? {
        PerplService.liquidationPrice(side: position.side, entry: position.entry, size: position.size, margin: projMargin, premium: position.premium, maintenanceFraction: market.maintMarginFraction)
    }

    /// The margin's result as it stands: a later check may have changed what the wait said.
    private var apiResult: PerplTrading.MarginResult? {
        guard case .settled(let result) = apiPhase else { return nil }
        return marginId.flatMap { perplTrading.marginResults[$0] } ?? result
    }

    /// The result in words, with the tone its icon, colour and haptic follow.
    private var apiText: PerplOutcomeText? {
        switch apiResult {
        case .added(let cns)?:
            return PerplOutcomeText(headline: PerpOnChainCopy.marginAdded(NumberStyle.units(cns, decimals: 6)), detail: nil, tone: .success)
        case .refused(let why, _)?:
            return PerplOutcomeText(headline: PerpActionCopy.marginNotAdded, detail: why, tone: .failure)
        case .notConfirmed?:
            return PerplOutcomeText(headline: PerpActionCopy.marginNotConfirmed, detail: PerpActionCopy.marginCheck, tone: .warning)
        case nil:
            return nil
        }
    }

    /// The terms can't change once the margin is on its way, or the wallet's is signing or done.
    private var termsLocked: Bool { apiPhase != .review && !apiPhase.isFailed || run.isRunning || run.isDone || run.sentSomething }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow("Position", verbatim: PositionText.amount(isLong: position.side == .long, size: position.size, asset: position.symbol), tint: position.side == .long ? .positive : .negative)
                    DetailRow("Current margin", PriceFormat.usdValue(position.margin))
                    DetailRow("Available", PriceFormat.usdValue(available))
                }
                Section {
                    HStack {
                        Text("Amount").foregroundStyle(.secondary)
                        Spacer()
                        TextField("0" as String, text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                            .disabled(termsLocked)
                        Text("AUSD").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        ForEach([0.25, 0.5, 1.0], id: \.self) { frac in
                            Button { amountText = plainAmount(available * frac) } label: {
                                frac == 1.0 ? Text("Max", comment: "The most allowed: a button or chip that fills in the whole balance, or the highest leverage or amount [tight]") : Text(verbatim: "\(Int(frac * 100))%")
                            }
                            .buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
                            .disabled(termsLocked)
                        }
                    }
                    if overBalance { Text("More than your available balance.").font(.caption).foregroundStyle(.negative) }
                } header: {
                    Text("Add margin")
                } footer: {
                    if route != nil { Paragraph("Signed and forwarded by your Perpl API key over the trading connection.") }
                }
                if amount > 0, !overBalance {
                    Section("After") {
                        DetailRow("Margin", PriceFormat.usdValue(projMargin))
                        DetailRow("Leverage", verbatim: "\(NumberStyle.number(projLeverage, maximumFractionDigits: 1))×")
                        DetailRow("Liq. price", verbatim: projLiquidation.map { NumberStyle.number($0) } ?? (market.maintMarginFraction == nil ? PositionText.unknown : "—"))
                    }
                }
                if !run.events.isEmpty { Section("Progress") { TransactionProgress(events: run.events, neutralConfirmation: true) } }
                if let settled { PerpOrderOutcomeSection(text: settled) }
                if case .failed(let message) = run.phase {
                    Section { InlineError(message: message) }.listRowBackground(Color.clear)
                }
                if let apiText {
                    PerpOrderOutcomeSection(text: apiText)
                    // A refusal at the gateway: nothing was forwarded, and the reopened sheet says how it will be sent.
                    if case .refused(_, true)? = apiResult, let failureLine {
                        Section { Paragraph(verbatim: failureLine).font(.footnote).foregroundStyle(.secondary) }.listRowBackground(Color.clear)
                    }
                }
                if case .failed(let message) = apiPhase {
                    Section {
                        InlineError(message: message)
                        if let failureLine { Paragraph(verbatim: failureLine).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Add Margin"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Once the request is written it can't be called back: "Close" (Perpl may still add it, and the result
                    // comes as a notice), "Done" when it is in; "Cancel" only while nothing has been sent.
                    Button(run.isDone || apiResult != nil ? "Done" : (marginId != nil || apiPhase == .sending ? "Close" : "Cancel")) { finish() }
                        .disabled(run.isRunning || holdingDone || apiPhase == .authorizing || apiPhase == .sending)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let route {
                        apiBar(route)
                    } else if run.isDone {
                        // The margin the position received, read from the receipt (Done held for the first moments).
                        ReceiptResultBar(settled: settled, reading: reading, holdingDone: holdingDone) { finish() }
                    } else if case .failed = run.phase, run.sentSomething {
                        // Already on the network: no re-confirm (it would replay the plan), as in ConfirmationSheet.
                        Text(TransactionRun.alreadySent).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                    } else if !session.canSign {
                        Paragraph(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        // Moving margin isn't in a passkey session's scope (MERA-PLAN §3): one Face ID when it's signed.
                        if session.isPasskeyAccount { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.unlisted.summary)) }
                        PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : "Add Margin", isBusy: run.isRunning, isDisabled: !canConfirm) {
                            Task {
                                if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm add margin")) { return }
                                let plan = env.perpl.addMarginPlan(market: market, amount: amount)
                                sentDescId = PerplReceipt.descId(ofPlan: plan)
                                run.start(plan, session: session, sender: env.sender)
                            }
                        }
                    }
                }
                .padding().frame(maxWidth: .infinity).background(.bar)
            }
            .interactiveDismissDisabled(run.isRunning || holdingDone || apiPhase == .sending || apiPhase == .authorizing)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        // The result's tone, once read: the margin read back is a success; a receipt that can't be read is a warning.
        .sensoryFeedback(trigger: settled?.tone) { _, tone in tone.flatMap(PerpOutcomeTone.feedback) }
        .sensoryFeedback(trigger: apiText?.tone) { _, tone in tone.flatMap(PerpOutcomeTone.feedback) }
        // Recorded when the margin settles, not when the sheet is dismissed: a settled sheet can be swiped away.
        .onChange(of: run.phase) { _, phase in
            if case .done(let hash) = phase {
                // A confirmed `revertOnFail` transaction already proves the margin went in: the row is true without a decode.
                Activity.record(ActivityRecord(kind: .deposit, title: tr("Added \(position.symbol) margin"), subtitle: "\(NumberStyle.number(amount)) AUSD", hash: hash, section: "perps", usd: amount), owner: session.address)
                readResult(hash)
            }
        }
        // Each new result headline over the trading connection, announced (not confirmed first, then added).
        .onChange(of: apiText?.headline) { _, headline in
            guard let headline, headline != announcedHeadline else { return }
            announcedHeadline = headline
            AccessibilityNotification.Announcement(headline).post()
        }
        .task {
            // The market's position now: what the margin is compared with on the chain.
            guard let route, let fresh = await perplTrading.readPosition(market: market, for: route) else { return }
            freshBefore = fresh.position
            freshBeforeAt = fresh.at
        }
        .onDisappear {
            // A result decided from now on posts its notice (and its Activity row, either way).
            if let marginId { perplTrading.setMarginPresented(marginId, false) }
        }
        #if DEBUG && targetEnvironment(simulator)
        // The scripted Perps demo only (`PerpsDemo`): its amount, and with Run this sheet's own confirm 2 s after it appears
        // (App Lock still asks).
        .task {
            guard perplTrading.isDemo else { return }
            if let amount = demoTerms?.amountText { amountText = amount }
            guard let demoAutoConfirm, let route else { return }
            try? await Task.sleep(for: demoAutoConfirm)
            confirmAPI(route)
        }
        #endif
    }

    /// Where the button was, on the trading connection's path: the button (again after a failure before anything was
    /// sent), "Sending to Perpl…", "Waiting for Perpl…" (closable after 3 s: the result comes as a notification and in
    /// Activity), then the result with Done.
    @ViewBuilder private func apiBar(_ route: PerplTrading.ActionAccount) -> some View {
        switch apiPhase {
        case .review, .failed, .authorizing:
            if !session.canSign {
                Paragraph(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                if session.isPasskeyAccount { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.unlisted.summary)) }
                PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : "Add Margin", isBusy: apiPhase == .authorizing, isDisabled: !canConfirm) {
                    confirmAPI(route)
                }
            }
        case .sending:
            HStack(spacing: 10) {
                ProgressView()
                Paragraph(verbatim: PerpOrderCopy.sending).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .waiting(_, let since, let acknowledged):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Paragraph(verbatim: acknowledged ? PerpOrderCopy.waiting : PerpOrderCopy.stillListening).font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if context.date.timeIntervalSince(since) >= 3 {
                        Paragraph(verbatim: PerpActionCopy.marginCanClose).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                }
            }
        case .settled:
            VStack(spacing: 8) {
                if let apiText { PerpOrderStatusBar(text: apiText) }
                PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
            }
        }
    }

    /// The confirm on the trading connection (A.3.1): ignored unless nothing is under way, and busy at once, before the
    /// App Lock prompt — a double tap can never send a second request.
    private func confirmAPI(_ route: PerplTrading.ActionAccount) {
        guard apiPhase == .review || apiPhase.isFailed else { return }
        apiPhase = .authorizing
        failureLine = nil
        Task { await addOverAPI(route) }
    }

    /// The margin over the trading connection: App Lock (as the wallet's margin asks it), the passkey session held for the
    /// send (GL-1), the amount checks the device can make before any step-up, then `PerplTrading.addMargin` — a passkey
    /// account's always asks first (MERA-PLAN §3) — which writes the row and, once this sheet is gone, the notice.
    private func addOverAPI(_ route: PerplTrading.ActionAccount, approval: MeraSession.StepUp? = nil) async {
        if approval == nil, settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm add margin")) {
            apiPhase = .review
            return
        }
        session.mera.beginAction()
        defer { session.mera.endAction() }
        // Refused on the device before any step-up: more than the account has free, or an amount that rounds to zero.
        if overBalance {
            apiPhase = .failed(PerpActionCopy.marginOverAvailable)
            return
        }
        if let problem = PerplOrders.problem(PerplOrders.addMargin(perpId: market.id, amountCNS: PerplService.toCNS(amount), accountId: route.accountId)) {
            apiPhase = .failed(problem)
            return
        }
        apiPhase = .sending
        do {
            let result = try await perplTrading.addMargin(market: market, amount: amount, account: route, before: freshBefore ?? position, approval: approval,
                                                          beforeAt: freshBefore != nil ? freshBeforeAt : nil) { id, acknowledged in
                marginId = id
                perplTrading.setMarginPresented(id, true)
                apiPhase = .waiting(id: id, since: Date(), acknowledged: acknowledged)
            }
            if case .refused(_, true) = result { failureLine = perplTrading.nothingSentLine(for: route) }
            apiPhase = .settled(result)
            onSettled()
        } catch is MeraSession.StepUpRequired where approval == nil {
            // MERA-PLAN §3: one pinned passkey ceremony approves this margin, then it is sent.
            do {
                let approval = try await session.mera.stepUp()
                await addOverAPI(route, approval: approval)
            } catch where isUserCancellation(error) {
                failureLine = perplTrading.nothingSentLine(for: route)
                apiPhase = .failed(TransactionRun.notSent)
            } catch {
                failureLine = perplTrading.nothingSentLine(for: route)
                apiPhase = .failed(describe(error))
            }
        } catch {
            // Refused on the device: the message says why, and nothing else needs saying.
            failureLine = (error as? PerplTradeError)?.isInvalidOrder == true ? nil : perplTrading.nothingSentLine(for: route)
            apiPhase = .failed(describe(error))
        }
    }

    /// Reads the receipt in a task of its own, only to word the result: the margin the position received, or — when it
    /// can't be read — that it confirmed and the position shows the margin (never that the margin is missing).
    private func readResult(_ hash: Data) {
        reading = true
        holdingDone = true
        Task { @MainActor in
            try? await Task.sleep(for: ReceiptResultBar.doneHold)
            holdingDone = false
        }
        let accountId = accountId
        let descId = sentDescId
        let perpl = env.perpl
        Task { @MainActor in
            let background = BackgroundTime("Perpl result") // not localized: the background task's name, never shown
            defer { background.end() }
            let requests = try? await perpl.receiptRequests(hash)
            if let accountId, let added = PerplReceipt.marginAdded(requests, accountId: accountId, descId: descId.map { BigUInt($0) }) {
                let amount = NumberStyle.units(added, decimals: 6)
                settled = PerplOutcomeText(headline: PerpOnChainCopy.marginAdded(amount), detail: nil, tone: .success)
            } else {
                settled = PerplOutcomeText(headline: PerpOnChainCopy.marginUnreadable, detail: nil, tone: .warning)
            }
            reading = false
            holdingDone = false
            onSettled()
            if let settled { AccessibilityNotification.Announcement(settled.headline).post() }
        }
    }

    private func plainAmount(_ value: Double) -> String {
        String(format: "%.2f", max(0, value))
    }

    private func finish() {
        // Done after a result (the wallet's or Perpl's), or closed while Perpl's is awaited: the screen behind reads again.
        let done = run.isDone || marginId != nil
        dismiss()
        if done { onDone() }
    }
}

/// Confirms and places an order through the authenticated Perpl trading connection (entry + optional TP/SL).
///
/// With the live outcome on at the tap (`live`, the owner's switch `PerplTrading.liveOutcomes`), the sheet follows the
/// order to what Perpl reported it did: filled (at what price, for what fee), partly filled, resting on the book, not
/// filled, refused — or, when Perpl's report doesn't come in time, that its result isn't confirmed yet. It can be closed
/// while it waits: `PerplTrading.track` keeps following the order, and the trade screen's status row shows the result.
/// Off, it is today's one-click sheet (`placeLegacy`): Perpl's acknowledgement, and the app-wide watcher reports a fill.
/// Nothing is ever resent from here: a second order needs a new tap on the ticket (GL-1, the path fixed at the tap).
struct AuthedOrderSheet: View {
    let market: PerpMarket
    let input: OrderInput
    let takeProfit: Double?
    let stopLoss: Double?
    let accountId: Int
    let sideColor: Color
    let summaryMargin: Double
    /// What the triggers close when it isn't the order's size: what is left on the new side of a position the order
    /// turns around (GT-6), with a note saying so.
    var triggerSize: Double? = nil
    var triggerNote: String? = nil
    /// The account's positions and orders as the Exchange last reported them, for the checks made where it is sent.
    var onChainPositions: [PerpPosition] = []
    var onChainOrders: [PerpOrder] = []
    /// The live outcome switch as it stood at the tap that opened this review: on, the sheet shows Perpl's result.
    var live = false
    /// The side of the position the order closes (`PerpCloseOrder.closes`), nil when it opens or adds.
    var closes: PositionSide? = nil
    /// The position held on this market at the tap, its side and size: what the order can grow.
    var held: (side: PositionSide, size: Double)? = nil
    /// Perpl's window for the order (`MarketContext.orderTTLBlocks`).
    var ttlBlocks: Int? = nil
    /// The markets the account's positions are read over (a read must cover every one it holds).
    var markets: [PerpMarket] = []
    /// This market's position at the last read before the tap, and when that read was: what the chain is compared with
    /// if Perpl's own report never comes (`PerplPositionEvidence`).
    var before: PerpPosition? = nil
    var beforeReadAt: Date? = nil
    /// An order that can grow the same side rests on this market (on the chain, or on Perpl's live list).
    var restingOnSide = false
    /// The entry went out (Perpl admitted it, or never answered, so it may be live) — before Done is tapped.
    var onSent: () -> Void = {}
    /// The sheet closed after the order was sent. `clearTicket`: it may have executed (filled, rests, not confirmed), so
    /// the ticket is cleared; false when it provably executed nothing, so it can be sent again as it is.
    let onDone: (_ clearTicket: Bool) -> Void

    @Environment(PerplTrading.self) private var perplTrading
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .review
    /// This market's position read when the sheet opened: the order's "before" when the read finished before the tap.
    @State private var freshBefore: (position: PerpPosition?, at: Date)?
    /// When the order started waiting for Perpl (the "you can close this" line shows after 3 s).
    @State private var waitingSince: Date?
    @State private var finished = false
    /// The result headline VoiceOver last announced: each new one is announced (not confirmed, then filled), once.
    @State private var announcedHeadline: String?
    @State private var leftoverCancel: TriggerCancelRequest?
    #if DEBUG && targetEnvironment(simulator)
    @Environment(\.perpsDemoAutoConfirm) private var demoAutoConfirm
    #endif

    enum Phase: Equatable { case review, sending, tracking(UUID), failed(String), legacyDone, legacyDoneWarning(String), legacyUnknown(String) }

    /// The order this sheet follows.
    private var tracked: PerplTrackedOrder? {
        if case .tracking(let id) = phase { return perplTrading.orders.order(id) }
        return nil
    }

    /// The entry's result, once Perpl (or the chain) decided it; nil while it waits.
    private var settled: PerplOrderOutcome? { tracked?.entry }

    /// The tone the order settled with, for the haptic (nil while waiting).
    private var settledTone: PerplOrderOutcome.Tone? { settled?.tone }

    /// The result's headline as it stands (nil while waiting): what VoiceOver announces each time it changes.
    private var settledHeadline: String? {
        guard let order = tracked, let entry = order.entry else { return nil }
        return PerplOutcomeText.order(entry, order.textContext).headline
    }

    private var isTracking: Bool { if case .tracking = phase { return true }; return false }

    /// The result is in and isn't "not confirmed": Done, not Close.
    private var isDecided: Bool { settled.map { !PerplTracker.isUnconfirmed($0) } ?? false }

    /// The legacy sheet: the entry was placed (with or without every trigger) — the sheet closes on "Done" and reloads.
    private var isPlaced: Bool { if case .legacyDone = phase { return true }; if case .legacyDoneWarning = phase { return true }; return false }

    /// The legacy sheet: the order was sent but Perpl never confirmed it: it may be live, so there is no resend.
    private var isUnknown: Bool { if case .legacyUnknown = phase { return true }; return false }

    /// Nothing was sent yet (or what was tried failed before it left): the order button shows.
    private var canOrder: Bool { phase == .review || { if case .failed = phase { return true }; return false }() }

    /// A passkey account's badge: its live session places an opening order on its own within the caps; a reduce-only
    /// close, or anything while locked, asks for Face ID (MERA-PLAN §3).
    private var scopeAssessment: MeraSession.Assessment? {
        guard session.isPasskeyAccount else { return nil }
        if input.reduceOnly { return .faceID(Mera.AlwaysAsk.closePosition.summary) }
        return session.mera.assessOrder(usd: Mera.SpendingCaps.notionalUSD(of: input))
    }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        DetailRow(Text(verbatim: tr(LocalizedStringResource("orderReview.market", defaultValue: "Market", comment: "A review row: the Perps market the order is on, next to its name (BTC-PERP) [tight]"))), Text(verbatim: "\(market.asset)-PERP"))
                        DetailRow("Side", input.side == .long ? "Long" : "Short", tint: sideColor)
                        if input.kind == .limit, let flagged = PerpOrderCopy.limitType(price: NumberStyle.number(input.price ?? market.mark, maximumFractionDigits: market.priceDecimals), postOnly: input.postOnly, reduceOnly: input.reduceOnly) {
                            DetailRow("Type", verbatim: flagged)
                        } else {
                            DetailRow("Type", input.kind == .market ? "Market · \(NumberStyle.basisPoints(input.slippageBps)) slippage" : "Limit at \(NumberStyle.number(input.price ?? market.mark, maximumFractionDigits: market.priceDecimals))")
                        }
                        DetailRow("Size", verbatim: "\(NumberStyle.number(input.size, maximumFractionDigits: market.lotDecimals)) \(market.asset)")
                        DetailRow("Leverage", verbatim: "\(NumberStyle.number(input.leverage, maximumFractionDigits: 1))×")
                        DetailRow("Margin", PriceFormat.usdValue(summaryMargin))
                        // Each closes this order's size, fixed when placed (security audit GT-5).
                        if let takeProfit { DetailRow("Take profit", "\(NumberStyle.number(takeProfit)) · closes \(NumberStyle.number(triggerSize ?? input.size)) \(market.asset)", tint: .positive) }
                        if let stopLoss { DetailRow("Stop loss", "\(NumberStyle.number(stopLoss)) · closes \(NumberStyle.number(triggerSize ?? input.size)) \(market.asset)", tint: .negative) }
                    } header: {
                        Text("Review Order · Perpl")
                    } footer: {
                        if let triggerNote, takeProfit != nil || stopLoss != nil {
                            Paragraph(verbatim: WordWrap.sentences(triggerNote, tr("Signed and forwarded by your Perpl API key over the trading connection.")))
                        } else {
                            Paragraph("Signed and forwarded by your Perpl API key over the trading connection.")
                        }
                    }
                    if canOrder, let scopeAssessment {
                        Section { SessionScopeBadge(assessment: scopeAssessment) }
                    }
                    if case .failed(let message) = phase {
                        Section { InlineError(message: message) }.listRowBackground(Color.clear)
                    }
                    if case .legacyUnknown(let message) = phase {
                        Section {
                            Label { Paragraph(verbatim: message) } icon: { Image(systemName: "questionmark.circle.fill") }
                                .modifier(ParagraphLabel())
                                .foregroundStyle(Color.attention).font(.footnote)
                        }
                    }
                    if phase == .legacyDone {
                        Section { Label("Order sent to Perpl.", systemImage: "checkmark.circle.fill").foregroundStyle(Color.positive) }
                    }
                    if case .legacyDoneWarning(let message) = phase {
                        Section {
                            Label("Order sent to Perpl.", systemImage: "checkmark.circle.fill").foregroundStyle(Color.positive)
                            Label { Paragraph(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                                .modifier(ParagraphLabel())
                                .foregroundStyle(Color.attention).font(.footnote)
                        }
                    }
                    if let order = tracked {
                        outcomeSection(order).id("outcome")
                    }
                }
                .listStyle(.insetGrouped)
                // The result comes in under the review: it is scrolled to once, and every new headline is announced
                // (a "not confirmed" first, then what Perpl decided).
                .onChange(of: settledHeadline) { _, headline in
                    guard let headline, headline != announcedHeadline else { return }
                    let first = announcedHeadline == nil
                    announcedHeadline = headline
                    if first { withAnimation { proxy.scrollTo("outcome", anchor: .top) } }
                    AccessibilityNotification.Announcement(headline).post()
                }
                // A take-profit or stop-loss that isn't known to be live is said the moment the order is followed: it is
                // scrolled to before the sheet can be closed.
                .onChange(of: isTracking) { _, tracking in
                    guard tracking, let order = tracked, let warning = PerpOrderCopy.triggerWarning(order) else { return }
                    withAnimation { proxy.scrollTo("outcome", anchor: .top) }
                    AccessibilityNotification.Announcement(warning).post()
                }
            }
            .navigationTitle(tr("Place Order"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isTracking {
                        Button(isDecided ? "Done" : "Close") { close() }
                    } else {
                        Button(isPlaced ? "Done" : isUnknown ? "Close" : "Cancel") { let reload = isPlaced || isUnknown; dismiss(); if reload { onDone(true) } }
                            .disabled(phase == .sending)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .interactiveDismissDisabled(phase == .sending)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(.success, trigger: isPlaced)
        // The order's result, felt: success, a warning, or an error; a cancel made elsewhere is no news.
        .sensoryFeedback(trigger: settledTone) { _, tone in
            switch tone {
            case .success?: return .success
            case .warning?: return .warning
            case .failure?: return .error
            case .neutral?, nil: return nil
            }
        }
        .task {
            // The market's position now: what the order is compared with if Perpl's own report never comes.
            guard live, let owner = session.address, let read = perplTrading.readPositions else { return }
            if let positions = try? await read(owner, markets.isEmpty ? [market] : markets) {
                freshBefore = (positions.first { $0.perpId == market.id }, Date())
            }
        }
        .sheet(item: $leftoverCancel) { request in
            CancelTriggersSheet(market: market, orders: request.orders, title: request.title, note: request.note) {}
        }
        .onDisappear {
            guard case .tracking(let id) = phase else { return }
            perplTrading.orders.setPresented(id, false)
            if !finished {
                finished = true
                onDone(PerplTracker.clearsTicket(perplTrading.orders.order(id)?.entry))
            }
        }
        #if DEBUG && targetEnvironment(simulator)
        // The scripted Perps demo only (`PerpsDemo`): with Run, this sheet's own live confirm 2 s after it appears (App Lock
        // still asks). Never the switch-off sheet, which writes Activity for the account on screen.
        .task {
            guard perplTrading.isDemo, live, let demoAutoConfirm else { return }
            try? await Task.sleep(for: demoAutoConfirm)
            if phase == .review { await place() }
        }
        #endif
    }

    /// Where the order button was: the live status, so it shows at the sheet's medium height.
    @ViewBuilder private var bottomBar: some View {
        switch phase {
        case .review, .failed:
            PrimaryButton(title: scopeAssessment?.needsFaceID == true ? "Confirm with \(BiometricGate.promptName)" : (input.side == .long ? "Long \(market.asset)" : "Short \(market.asset)"), foreground: .onStatus) {
                Task { if live { await place() } else { await placeLegacy() } }
            }
            .tint(sideColor)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        case .sending:
            HStack(spacing: 10) {
                ProgressView()
                Paragraph(verbatim: PerpOrderCopy.sending).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.bar)
        case .tracking:
            trackingBar.padding().frame(maxWidth: .infinity).background(.bar)
        case .legacyDone, .legacyDoneWarning, .legacyUnknown:
            EmptyView()
        }
    }

    @ViewBuilder private var trackingBar: some View {
        if let order = tracked {
            if let entry = order.entry, !PerplTracker.isUnconfirmed(entry) {
                VStack(spacing: 8) {
                    PerpOrderStatusBar(text: PerplOutcomeText.order(entry, order.textContext))
                    if entry.executedNothing {
                        Paragraph(verbatim: PerpOrderCopy.stillInTicket).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    PrimaryButton(title: "Done", systemImage: "checkmark") { close() }
                }
            } else if let entry = order.entry {
                VStack(spacing: 8) {
                    PerpOrderStatusBar(text: PerplOutcomeText.order(entry, order.textContext))
                    PrimaryButton(title: "Close", systemImage: "xmark") { close() }
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressView()
                            Paragraph(verbatim: order.acknowledged ? PerpOrderCopy.waiting : PerpOrderCopy.stillListening).font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let waitingSince, context.date.timeIntervalSince(waitingSince) >= 3 {
                            Paragraph(verbatim: PerpOrderCopy.canClose(market: "\(market.asset)-PERP")).font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        PrimaryButton(title: "Close", systemImage: "xmark") { close() }
                    }
                }
            }
        }
    }

    /// The order's result in the list: the headline and detail, its take-profit and stop-loss, any warning, and a
    /// "View" link to the transaction Perpl filled it in.
    @ViewBuilder private func outcomeSection(_ order: PerplTrackedOrder) -> some View {
        let lines = outcomeLines(order)
        if let entry = order.entry {
            let words = PerplOutcomeText.order(entry, order.textContext)
            // Perpl never answered the entry: its result can't be known yet, and the triggers weren't sent (GL-1).
            let text = PerplTracker.isUnconfirmed(entry) && !order.acknowledged
                ? PerplOutcomeText(headline: words.headline, detail: PerpOrderCopy.unknown(takeProfit: order.takeProfit != nil, stopLoss: order.stopLoss != nil), tone: words.tone)
                : words
            let link = entry.fill?.txid.flatMap { Data(hex: $0) }.map(Monad.explorerTransaction)
            let leftovers = perplTrading.liveTriggers(of: order.id)
            PerpOrderOutcomeSection(text: text, lines: lines, link: link) {
                if !leftovers.isEmpty {
                    Button(leftovers.count == 1 ? "Cancel It" : "Cancel Them") {
                        leftoverCancel = TriggerCancelRequest(orders: leftovers, title: "Leftover TP/SL", note: "There is no open position on \(market.asset) for these to close.")
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.negative)
                }
            }
        } else if !lines.isEmpty {
            PerpOrderOutcomeSection(text: nil, lines: lines)
        }
    }

    /// The lines under the result: a provisional failure while waiting, each take-profit / stop-loss as it settles, and
    /// the warning about triggers that aren't known to be live — from the moment the order is followed, whatever the entry
    /// is doing (`PerpOrderCopy.triggerWarning`).
    private func outcomeLines(_ order: PerplTrackedOrder) -> [PerpOrderOutcomeLine] {
        var lines: [PerpOrderOutcomeLine] = []
        if order.entry == nil, let provisional = order.provisional {
            lines.append(PerpOrderOutcomeLine(text: PerplOutcomeText.provisional(provisional), tone: .warning))
        }
        let entry = order.entry
        let executedNothing = entry?.executedNothing == true
        let filled = entry?.fill != nil || entry.map(PerplTracker.isObserved) == true
        let closing = "\(NumberStyle.number(triggerSize ?? input.size)) \(market.asset)"
        var cancelledWith: [PerplTriggerKind] = []
        var stillArmed: [PerplTriggerKind] = []
        var mayBeArmed: [PerplTriggerKind] = []
        for kind in [PerplTriggerKind.takeProfit, .stopLoss] {
            // A refused, unanswered or never-sent trigger is said by the warning below.
            guard let child = order.child(kind), child.accepted else { continue }
            let price = NumberStyle.number(child.price)
            let tp = kind == .takeProfit
            switch child.outcome {
            case nil:
                lines.append(PerpOrderOutcomeLine(text: PerpOrderCopy.checking(kind), tone: nil))
            case .armed?:
                if executedNothing {
                    // "Cancelled with it" only on evidence: a live list read after the entry no longer has it.
                    if child.armedWithoutPosition { stillArmed.append(kind) }
                    else if child.checkedNotListed { cancelledWith.append(kind) }
                    else if perplTrading.isFollowing(order.id) { lines.append(PerpOrderOutcomeLine(text: PerpOrderCopy.checking(kind), tone: nil)) }
                    else { mayBeArmed.append(kind) }
                } else if filled {
                    lines.append(PerpOrderOutcomeLine(text: tp ? tr("Take-profit set at \(price), closing \(closing).") : tr("Stop-loss set at \(price), closing \(closing)."), tone: .success))
                } else {
                    lines.append(PerpOrderOutcomeLine(text: PerpOrderCopy.accepted(kind, price: price), tone: .success))
                }
            case .triggered?:
                // "At once" only when its own wait right after placing it saw it fire; later, Perpl's words for a trigger.
                lines.append(PerpOrderOutcomeLine(text: child.settledDuringFollow ? PerpOrderCopy.triggeredAtOnce(kind, price: price) : PerpOrderCopy.triggeredLater(kind),
                                                  tone: .warning))
            case .cancelled(let reason)?:
                if executedNothing { cancelledWith.append(kind) }
                else if child.settledDuringFollow {
                    lines.append(PerpOrderOutcomeLine(text: tp ? tr("Take-profit not placed: \(reason.message)") : tr("Stop-loss not placed: \(reason.message)"), tone: .warning))
                } else {
                    // Placed, then cancelled later (from Orders, or after the other one fired): no cause is guessed.
                    lines.append(PerpOrderOutcomeLine(text: PerpOrderCopy.cancelledLater(kind), tone: .warning))
                }
            case .failed(let reason)?:
                lines.append(PerpOrderOutcomeLine(text: tp ? tr("Take-profit not placed: \(reason.message)") : tr("Stop-loss not placed: \(reason.message)"), tone: .warning))
            case .expired?:
                lines.append(PerpOrderOutcomeLine(text: tp ? tr("Take-profit expired") : tr("Stop-loss expired"), tone: .warning))
            case .unconfirmed?:
                lines.append(PerpOrderOutcomeLine(text: PerpOrderCopy.notListed(kind), tone: .warning))
            case .filled?, .partlyFilled?, .resting?, .notFilled?, .observed?:
                break
            }
        }
        if let text = PerpOrderCopy.cancelledWith(takeProfit: cancelledWith.contains(.takeProfit), stopLoss: cancelledWith.contains(.stopLoss)) {
            lines.append(PerpOrderOutcomeLine(text: text, tone: .neutral))
        }
        if let text = PerpOrderCopy.stillArmed(takeProfit: stillArmed.contains(.takeProfit), stopLoss: stillArmed.contains(.stopLoss)) {
            lines.append(PerpOrderOutcomeLine(text: text, tone: .warning))
        }
        // No live list could say yet whether they went with the entry: said, with the Cancel when Perpl lists them.
        if let text = PerpOrderCopy.mayStillBeArmed(takeProfit: mayBeArmed.contains(.takeProfit), stopLoss: mayBeArmed.contains(.stopLoss)) {
            lines.append(PerpOrderOutcomeLine(text: text, tone: .warning))
        }
        // Triggers never sent, refused or never answered: said from the start, whatever the entry is doing (the legacy
        // sheet said it at once too) — never only once the entry is in.
        if let warning = PerpOrderCopy.triggerWarning(order) {
            lines.append(PerpOrderOutcomeLine(text: warning, tone: .warning))
        }
        return lines
    }

    /// Closes the sheet once the order was sent: the order keeps being followed; the ticket is cleared unless the order
    /// provably executed nothing (a blind resend of an order that may have executed could double it).
    private func close() {
        let entry = tracked?.entry
        if case .tracking(let id) = phase { perplTrading.orders.setPresented(id, false) }
        dismiss()
        guard !finished else { return }
        finished = true
        onDone(PerplTracker.clearsTicket(entry))
    }

    /// Records the TP/SL Perpl admitted (or never answered: they may be live) on this device, shown as unverified until
    /// Perpl's list says otherwise (Perpl offers no read-back for keeper triggers). Returns each echo's id by kind: the
    /// order removes only its own echoes later, never another order's of the same kind (GT-1).
    @discardableResult
    private func recordTriggerEchoes(_ result: PerplTrading.BracketResult) -> [PerplTriggerKind: UUID] {
        var placed: [PlacedTrigger] = []
        if let tp = takeProfit, result.takeProfit == true || result.takeProfitUnknown {
            placed.append(PlacedTrigger(perpId: market.id, symbol: market.asset, kind: .takeProfit, price: tp, size: input.size, positionLong: input.side == .long))
        }
        if let sl = stopLoss, result.stopLoss == true || result.stopLossUnknown {
            placed.append(PlacedTrigger(perpId: market.id, symbol: market.asset, kind: .stopLoss, price: sl, size: input.size, positionLong: input.side == .long))
        }
        var ids: [PerplTriggerKind: UUID] = [:]
        for echo in TriggerStore.record(placed, owner: session.address) { ids[echo.kind == .takeProfit ? .takeProfit : .stopLoss] = echo.id }
        return ids
    }

    /// The live outcome: the order is sent, then followed to Perpl's result (`PerplTrading.track`), which records its
    /// Activity row and posts its notice when the result is in — never at the acknowledgement.
    /// `approval`: a passkey account's step-up for this one order, when its session couldn't place it prompt-free.
    private func place(approval: MeraSession.StepUp? = nil) async {
        // App Lock covers leveraged orders too (this path signs with the Perpl API key, not a confirmation sheet).
        if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm order")) { return }
        // A passkey session (and its trading socket) outlives leaving the app until this bracket is sent (GL-1).
        session.mera.beginAction()
        defer { session.mera.endAction() }
        phase = .sending
        // From before the first frame: the app-wide watcher waits for this order's own result instead of announcing its
        // fill first (the entry's and its TP/SL's acknowledgements can take seconds). Let go unless the order is followed.
        let expectation = perplTrading.expectOrder(input, held: held)
        var followed = false
        defer { if !followed { perplTrading.releaseOrderExpectation(expectation) } }
        do {
            let result = try await perplTrading.submitBracket(input: input, accountId: accountId, takeProfit: takeProfit, stopLoss: stopLoss, env: env, ttlBlocks: 100, approval: approval,
                                                              onChainPositions: onChainPositions, onChainOrders: onChainOrders)
            guard result.entry, let tracking = result.tracking else { phase = .failed(result.error ?? tr("Perpl rejected the order.")); return }
            onSent()
            let echoes = recordTriggerEchoes(result)
            let id = perplTrading.track(tracking, input: input, takeProfit: takeProfit, stopLoss: stopLoss, closes: closes, held: held, ttlBlocks: ttlBlocks,
                                        before: freshBefore.map { $0.position } ?? before, beforeReadAt: freshBefore?.at ?? beforeReadAt, restingOnSide: restingOnSide,
                                        echoes: echoes, expectation: expectation)
            followed = true
            perplTrading.orders.setPresented(id, true)
            waitingSince = Date()
            phase = .tracking(id)
        } catch is MeraSession.StepUpRequired where approval == nil {
            // A passkey account whose session can't place this order prompt-free (locked, over a cap, a reduce-only
            // close): one pinned passkey ceremony approves this order and opens a new session, then it is placed.
            do {
                let approval = try await session.mera.stepUp()
                await place(approval: approval)
            } catch where isUserCancellation(error) {
                phase = .failed(TransactionRun.notSent)
            } catch {
                phase = .failed(describe(error))
            }
        } catch let unanswered as PerplTrading.EntryUnanswered {
            // The entry went out and Perpl never answered: it may be live. It is followed like any other order (never
            // resent): Perpl's late report, its history or the chain may still say what it did. Its triggers weren't sent.
            onSent()
            let id = perplTrading.track(unanswered.tracking, input: input, takeProfit: takeProfit, stopLoss: stopLoss, closes: closes, held: held, ttlBlocks: ttlBlocks,
                                        before: freshBefore.map { $0.position } ?? before, beforeReadAt: freshBefore?.at ?? beforeReadAt, restingOnSide: restingOnSide,
                                        expectation: expectation)
            followed = true
            perplTrading.orders.setPresented(id, true)
            waitingSince = Date()
            phase = .tracking(id)
        } catch {
            phase = .failed(describe(error))
        }
    }

    /// Today's one-click sheet (the live outcome off at the tap): Perpl's acknowledgement is the end of it, recorded and
    /// announced as an acknowledgement; the app-wide watcher reports the fill.
    private func placeLegacy(approval: MeraSession.StepUp? = nil) async {
        // App Lock covers leveraged orders too (this path signs with the Perpl API key, not a confirmation sheet).
        if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm order")) { return }
        // A passkey session (and its trading socket) outlives leaving the app until this bracket is sent (GL-1).
        session.mera.beginAction()
        defer { session.mera.endAction() }
        phase = .sending
        do {
            // Bracket placement reports per-frame acceptance, so we record only the TP/SL Perpl actually admitted and
            // can warn if the entry opened without a requested protection (an unprotected position the user must know
            // about). Perpl offers no read-back for keeper triggers, so the accepted ones are remembered locally.
            let result = try await perplTrading.submitBracket(input: input, accountId: accountId, takeProfit: takeProfit, stopLoss: stopLoss, env: env, ttlBlocks: 100, approval: approval,
                                                              onChainPositions: onChainPositions, onChainOrders: onChainOrders)
            guard result.entry else { phase = .failed(result.error ?? tr("Perpl rejected the order.")); return }
            onSent()
            recordTriggerEchoes(result)

            let warning = triggerWarning(tp: takeProfit == nil || result.takeProfit == true ? nil : result.takeProfitUnknown,
                                         sl: stopLoss == nil || result.stopLoss == true ? nil : result.stopLossUnknown)
            phase = warning.map { .legacyDoneWarning($0) } ?? .legacyDone
            // notify:false — this advanced path posts its own fills-gated notification just below, so a unified
            // notification here would double it.
            // KNOWN EXCEPTION to "volume only from what filled" (owner decision pending, real-time spec §8): with the live
            // outcome switched off, this path never learns whether the order filled, so its row carries the requested
            // notional at the mark, as it always has — an order that fills nothing still adds to platform_volume. It
            // applies only while the owner's kill switch `perpsLiveOutcome` is off (the live path records only fills). Recording nil
            // here instead would drop all switch-off volume to zero, since the watcher's fill notice carries none.
            let perp = "\(market.asset)-PERP"
            let kind = input.kind == .market
                ? tr(LocalizedStringResource("Market", comment: "Order type: a market order, which fills at once at the market price. [tight]"))
                : tr(LocalizedStringResource("Limit", comment: "Order type: rests at the price you set until it fills. [tight]"))
            Activity.record(ActivityRecord(kind: .perp, title: input.side == .long ? tr("Long \(perp)") : tr("Short \(perp)"), subtitle: "\(NumberStyle.number(input.size)) \(market.asset) · \(kind)", hash: nil, usd: input.size * market.mark > 0 ? input.size * market.mark : nil), owner: session.address, notify: false)
            if settings.notificationsEnabled, settings.notifyFills {
                let side = input.side == .long
                    ? tr(LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]"))
                    : tr(LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]"))
                Notifications.perpOrder(PerpOrderNotice(acknowledged: input.kind), side: side, market: "\(market.asset)-PERP", perpId: market.id)
            }
        } catch is MeraSession.StepUpRequired where approval == nil {
            // A passkey account whose session can't place this order prompt-free (locked, over a cap, a reduce-only
            // close): one pinned passkey ceremony approves this order and opens a new session, then it is placed.
            do {
                let approval = try await session.mera.stepUp()
                await placeLegacy(approval: approval)
            } catch where isUserCancellation(error) {
                phase = .failed(TransactionRun.notSent)
            } catch {
                phase = .failed(describe(error))
            }
        } catch is PerplTrading.EntryUnanswered {
            // The entry frame went out but was never acknowledged: it may be live. Resending would place a second
            // order, so this sheet only closes (and reloads orders and positions) from here. Its triggers are sent only
            // after the entry is answered, so none of them went out (GL-1): if the entry is live, it has no TP/SL.
            onSent()
            phase = .legacyUnknown(PerpOrderCopy.unknown(takeProfit: takeProfit != nil, stopLoss: stopLoss != nil))
        } catch let error as PerplTradeError where error.outcomeUnknown {
            onSent()
            phase = .legacyUnknown(PerpOrderCopy.unknown(takeProfit: takeProfit != nil, stopLoss: stopLoss != nil))
        } catch {
            phase = .failed(describe(error))
        }
    }

    /// What to say about requested triggers that aren't known to be live: `false` refused (or never sent), `true`
    /// sent but unanswered — it may be live, so it must not be placed again blindly (security audit GL-1). Refused
    /// ones are set again from the position's TP/SL, not by opening more size (GT-1).
    /// In the app's language; each combination is a sentence of its own.
    private func triggerWarning(tp: Bool?, sl: Bool?) -> String? {
        var parts: [String] = []
        let market = input.kind == .market
        switch (tp == false, sl == false) {
        case (true, true):
            parts.append(market ? tr("Position opened, but Perpl didn't accept the take-profit and stop-loss. Set them with TP/SL on the position.")
                                : tr("Order sent, but Perpl didn't accept the take-profit and stop-loss. Set them with TP/SL on the position once the order fills."))
        case (true, false):
            parts.append(market ? tr("Position opened, but Perpl didn't accept the take-profit. Set it with TP/SL on the position.")
                                : tr("Order sent, but Perpl didn't accept the take-profit. Set it with TP/SL on the position once the order fills."))
        case (false, true):
            parts.append(market ? tr("Position opened, but Perpl didn't accept the stop-loss. Set it with TP/SL on the position.")
                                : tr("Order sent, but Perpl didn't accept the stop-loss. Set it with TP/SL on the position once the order fills."))
        case (false, false):
            break
        }
        switch (tp == true, sl == true) {
        case (true, true):
            parts.append(tr("Order status unknown for the take-profit and stop-loss — Perpl didn't confirm them. Check Open Orders before placing them again."))
        case (true, false):
            parts.append(tr("Order status unknown for the take-profit — Perpl didn't confirm it. Check Open Orders before placing it again."))
        case (false, true):
            parts.append(tr("Order status unknown for the stop-loss — Perpl didn't confirm it. Check Open Orders before placing it again."))
        case (false, false):
            break
        }
        return parts.isEmpty ? nil : WordWrap.sentences(parts)
    }
}

// MARK: - Order ticket state

struct OrderTicket {
    enum AmountUnit { case asset, usd }
    var side: PositionSide = .long
    var kind: OrderKind = .market
    var sizeText = ""
    var priceText = ""
    var leverage: Double = 2
    var reduceOnly = false
    var postOnly = false
    var maxSlippageEnabled = false
    var slippageBps = 50
    var tpslEnabled = false
    var takeProfitText = ""
    var stopLossText = ""
    var amountUnit: AmountUnit = .asset

    /// Reduce-Only / Post-Only are Limit-only flags; a Market order must never carry them (it would change the order's
    /// meaning and, for reduceOnly, skip the margin guard below). This is the single source of truth — even if a stale
    /// flag survives a mode switch, the effective value here is always false for a market order.
    var effectiveReduceOnly: Bool { kind == .limit && reduceOnly }
    var effectivePostOnly: Bool { kind == .limit && postOnly }
    /// TP/SL only on an order that opens or adds (security audit GT-6): on a reduce-only order its triggers would close
    /// the side the account doesn't hold. Also enforced in `PerplTrading`.
    var effectiveTPSL: Bool { tpslEnabled && !effectiveReduceOnly }

    func baseSize(market: PerpMarket, price: Double) -> Double {
        let typed = sizeText.perpDouble ?? 0
        guard typed > 0, price > 0 else { return 0 }
        let raw = amountUnit == .usd ? typed / price : typed
        let scale = pow(10, Double(market.lotDecimals))
        return (raw * scale).rounded(.down) / scale
    }

    /// What's wrong with the ticket, in the app's language.
    /// - mark: the live mark the order is measured against (the market's listed mark when the live one is unknown).
    func problem(market: PerpMarket, mark: Double, account: PerpAccount?, available: Double) -> String? {
        let ref = mark > 0 ? mark : market.mark
        let price = kind == .limit ? (priceText.perpDouble ?? ref) : ref
        let size = baseSize(market: market, price: price)
        guard size > 0 else { return amountUnit == .usd ? tr("Enter an amount in AUSD.") : tr("Enter a size in \(market.asset).") }
        if kind == .limit, (priceText.perpDouble ?? 0) <= 0 { return tr("Enter a limit price.") }
        if kind == .limit, let limit = priceText.perpDouble, let reason = Self.offTickProblem(price: limit, market: market) { return reason }
        if kind == .limit, let limit = priceText.perpDouble, let reason = Self.throughMarkProblem(price: limit, side: side, mark: mark, market: market) { return reason }
        if account == nil, !effectiveReduceOnly { return tr("Deposit AUSD to open a trading account first.") }
        if account != nil, !effectiveReduceOnly {
            if size * price / max(leverage, 1) > available * 1.0001 { return tr("Not enough available margin.") }
        }
        return nil
    }

    /// A limit more than 5% through the mark fills at once as a taker: most often a decimal slip (1000x, in any locale),
    /// not a price anyone meant. Purely numeric; an unknown mark (0) blocks nothing. A buy (long) is refused above
    /// mark x 1.05, a sell (short) below mark x 0.95.
    static func throughMarkProblem(price: Double, side: PositionSide, mark: Double, market: PerpMarket) -> String? {
        guard mark.isFinite, mark > 0, price.isFinite, price > 0 else { return nil }
        let above = side == .long && price > mark * 1.05
        let below = side == .short && price < mark * 0.95
        guard above || below else { return nil }
        let limit = NumberStyle.number(price, maximumFractionDigits: market.priceDecimals)
        let markText = NumberStyle.number(mark)
        return above ? tr("Limit \(limit) is above the mark (\(markText)) and would fill at once. Check the price.")
            : tr("Limit \(limit) is below the mark (\(markText)) and would fill at once. Check the price.")
    }

    /// A limit between ticks: refused rather than rounded, so the price reviewed is the price signed.
    static func offTickProblem(price: Double, market: PerpMarket) -> String? {
        guard PerplTriggerRules.ticks(price, decimals: market.priceDecimals) == nil else { return nil }
        let d = market.priceDecimals
        return d == 0 ? tr("The limit price must be a whole number on \(market.asset).")
            : tr("The limit price can have at most \(d) decimal places on \(market.asset).")
    }

    func input(market: PerpMarket, refPrice: Double) -> OrderInput {
        OrderInput(market: market, side: side, kind: kind, size: baseSize(market: market, price: refPrice), price: kind == .limit ? priceText.perpDouble : nil, leverage: leverage, reduceOnly: effectiveReduceOnly, slippageBps: slippageBps, postOnly: effectivePostOnly)
    }
}

extension String {
    /// Parses a user-typed price, size or trigger (`Amount.fieldNumber`). The decimal pad shows the locale separator
    /// ("," across much of Europe/LatAm) while our own writers (`plainSize`) emit POSIX "."; a pasted "66,000" in en_US
    /// is 66000, never 66 (audit F4), and "0,5" is one half in every locale, never 5.
    var perpDouble: Double? { Amount.fieldNumber(self) }
}
