// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadView.swift LaunchDetailView (42cd8c7 sha256:e09b1e764833)
// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadView.swift LaunchTradeRow (42cd8c7 sha256:7e02fee967bf)
// Stellar copy of ios/DyorHQ/Home/HomeView.swift PriceChart (42cd8c7 sha256:8fa76a8065f3)
// A Stellar launch's page (docs/DESIGN-stellar-parity.md §8.10.2, §8.10.5; docs/DESIGN-stellar-contracts-v2.md §21).
// Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import Charts
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// One coin on Stellar, laid out as Monad's `LaunchDetailView` lays out one: its price and graduation gauge, its stats,
/// the price chart, the curve ticket while it trades, its graduation (pending, delayed, done) or its refunds, the
/// viewer's holdings and holder rewards, its creator fees and fee recipient, its recent trades and what it is.
///
/// Figures come from viewer reads (the launch's row and trades, and launchpad v2's live state), so the page fills with
/// or without a session (decision 6); a trade, a claim or any other action starts one first (`LaunchV2Store`). A coin
/// launchpad v2 doesn't know is on the retired v1 launchpad: it can be viewed, sold on its curve and its fees claimed,
/// and nothing else, as on Monad's retired stacks.
///
/// Each part's read keeps its last good figures when a later one fails, and says so with Retry (`reloads`).
struct StellarLaunchDetailView: View {
    let token: String
    @Environment(\.stellarSession) private var session
    @Environment(Router.self) private var router
    @State private var launches: LaunchV2Store?
    /// The coin's board row until its page is read, then the page's own.
    @State private var row: StellarLaunch?
    @State private var detail: StellarLaunchDetail?
    @State private var detailUnread = false
    /// Launchpad v2's live state; nil for a retired launch once `stateRead`.
    @State private var state: StellarLaunchStateV2?
    @State private var stateRead = false
    @State private var stateUnread = false
    /// Retry, a settled action and a pull to refresh read the page again: one read at a time, cancelled with the page.
    @State private var reloads = 0
    /// A coin Create launched seconds ago (`justLaunched`) whose row the indexer hasn't recorded yet (its page read
    /// answers 404): the page reads it again every few seconds, up to `rowWaitLimit` times, before it says it couldn't be
    /// read.
    @State private var awaitingRow = false
    @State private var rowWaits = 0
    @State private var side: Side = .buy
    @State private var amountText = ""
    @State private var quote: LaunchV2Quote?
    /// A retired launch's sale quote (v1).
    @State private var retiredQuote: StellarLaunchQuote?
    @State private var quoteError: String?
    @State private var review: Review?
    @State private var changingRecipient = false

    /// `launch`: the coin's board row, which the page shows until its own read lands.
    init(token: String, launch: StellarLaunch? = nil) {
        self.token = token
        _row = State(initialValue: launch)
    }

    private enum Side: Hashable { case buy, sell }

    /// What reads the page again: Retry, a settled action or a pull to refresh (`reloads`), and the session's store.
    private struct Reading: Equatable {
        let reloads: Int
        let store: ObjectIdentifier?
    }

    /// Where the coin stands, from launchpad v2's state (or, for a retired launch, its row).
    enum Phase { case bonding, graduating, delayed, graduated, refund }

    /// A review the page opens (§8.10.5).
    private enum Review: Identifiable {
        case trade, graduate(fallback: Bool), markStuck, rescue, claimCreator, claimOwed, claimRewards, recipient(LaunchV2RecipientChange)

        var id: String {
            switch self {
            case .trade: "trade"
            case .graduate(let fallback): fallback ? "fallback" : "graduate"
            case .markStuck: "markStuck"
            case .rescue: "rescue"
            case .claimCreator: "claimCreator"
            case .claimOwed: "claimOwed"
            case .claimRewards: "claimRewards"
            case .recipient(let change): "recipient-\(change)"
            }
        }
    }

    private var store: LiteStore? { session?.store }
    private var coin: StellarLaunch? { detail?.launch ?? row }
    private var symbol: String { coin?.symbol ?? "" }
    private var canAct: Bool { Self.canAct(canSign: session?.canSign ?? false, symbol: symbol) }

    /// Every action needs a session that can sign and the coin's row read: its ticker names the review, the activity and
    /// the notification, so nothing opens while the page has none.
    static func canAct(canSign: Bool, symbol: String) -> Bool { canSign && !symbol.isEmpty }

    /// On the retired v1 launchpad: the row's generation says, else launchpad v2 not knowing the launch once its state
    /// was read.
    private var isRetired: Bool { Self.isRetired(generation: coin?.generation, stateRead: stateRead, state: state) }

    static func isRetired(generation: Int?, stateRead: Bool, state: StellarLaunchStateV2?) -> Bool {
        if let generation { return generation == 1 }
        return stateRead && state == nil
    }

    /// Graduate, like every other action, waits for launchpad v2's state to say its graduation is open; a retired launch
    /// graduates on v1. While neither is known (the state unread, or its read failed) there is no Graduate, so no plan is
    /// built for the wrong launchpad.
    static func offersGraduate(retired: Bool, status: StellarLaunchStatusV2?) -> Bool {
        retired || status?.actions.graduate == true
    }

    private var phase: Phase? { Self.phase(state?.status, coin: coin) }

    /// The phase launchpad v2's `status` says; until it is read (and for a retired launch, which has none), the one its
    /// row says. Nil while neither is read: the page shows no phase, ticket or graduation as fact (§8.10.2).
    static func phase(_ status: StellarLaunchStatusV2?, coin: StellarLaunch?) -> Phase? {
        if let status {
            switch status.phase {
            case "graduated": return .graduated
            case "rescued": return .refund
            case "completed": return status.stuck ? .delayed : .graduating
            default: return .bonding
            }
        }
        guard let coin else { return nil }
        if coin.graduated { return .graduated }
        return coin.completed ? .graduating : .bonding
    }

    // MARK: Figures

    /// The quote asset: its registry id ("XLM", "USDC"), code and contract.
    private var quoteID: String { state?.quote.id ?? coin.flatMap { store?.asset($0.quote)?.id } ?? coin?.quote ?? "" }
    private var quoteCode: String { state?.quote.code ?? coin?.quoteCode ?? coin.flatMap { store?.asset($0.quote)?.code } ?? "" }
    private var quoteContract: String { state?.quote.contract ?? coin?.quote ?? "" }
    private var quoteIsXLM: Bool { quoteID == "XLM" }

    /// The graduation venue's name, as the API names it (Soroswap, O7).
    private var venueName: String { state?.status.graduatedVenue?.name ?? state?.status.venue.name ?? "Soroswap" } // not localized: a venue's name
    private var fallbackName: String { state?.status.fallback.name ?? "Soroswap" } // not localized: a venue's name

    /// The quote asset's dollar price, from the coin's own price in it and in dollars.
    private var quoteUSD: Double? {
        guard let usd = coin?.priceUsd, let price = coin?.priceQuote.flatMap(Double.init), price > 0, usd > 0 else { return nil }
        return usd / price
    }

    private var priceText: String {
        guard let price = coin?.priceQuote.flatMap(Double.init) else { return "—" }
        return "\(NumberStyle.number(price)) \(quoteCode)"
    }

    private var marketCapText: String {
        guard let cap = coin?.marketCapQuote.flatMap(Double.init) else { return "—" }
        return "\(NumberStyle.number(cap, compact: true)) \(quoteCode)"
    }

    /// The coins in existence: the supply less every burn (about 900M after the graduation burn).
    private var totalSupply: Int64? {
        guard let coin, let supply = Int64(coin.supply) else { return nil }
        return coin.circulating.flatMap { Int64($0) } ?? supply - (coin.burned.flatMap { Int64($0) } ?? 0)
    }

    /// Fully diluted value in the quote: the price × the total supply.
    private var fdvQuote: Double? {
        guard let price = coin?.priceQuote.flatMap(Double.init), let totalSupply else { return nil }
        return price * Double(totalSupply) / 1e7
    }

    private var progress: Double { coin.map(StellarLaunchMath.progress) ?? 0 }
    private var percent: Int { coin.map(StellarLaunchMath.progressPercent) ?? 0 }

    private var holders: (text: String, incomplete: Bool) {
        Self.holders(detail?.stats?.holders ?? coin?.holders, complete: detail?.stats?.holdersComplete ?? coin?.holdersComplete)
    }

    /// The holder count as the stats show it: "—" until read, and a minimum ("5+") with its footnote when some of the
    /// coin's transfers couldn't be read.
    static func holders(_ count: Int?, complete: Bool?) -> (text: String, incomplete: Bool) {
        guard let text = StellarLaunchMath.holdersText(count, complete: complete) else { return ("—", false) }
        return (text, complete == false)
    }

    private var volumeText: String {
        if let usd = detail?.stats?.volume24hUsd ?? coin?.volume24hUsd { return PriceFormat.usdValue(usd) }
        guard let volume = (detail?.stats?.volume24hQuote ?? coin?.volume24hQuote).flatMap(Double.init) else { return "—" }
        return "\(NumberStyle.number(volume, compact: true)) \(quoteCode)"
    }

    /// The viewer's coins and quote balance, in base units.
    private var tokenBalance: Int64 { detail?.you.flatMap { Int64($0.balance) } ?? store?.maxAmount(asset: token, stepKind: "launch_sell") ?? 0 }
    private var quoteBalance: Int64 { store?.account?.balance(quoteID) ?? 0 }

    /// The amount typed, in base units.
    private var amountUnits: Int64 { StellarAmount.parse(amountText) ?? 0 }

    /// What the ticket trades: a buy or a sale on the curve, or a refund at the fixed rate.
    private var tradeSide: StellarTradeQuoteV2.Side {
        if phase == .refund { return .refund }
        return side == .buy ? .buy : .sell
    }

    private var buysOpen: Bool { !isRetired && (state?.status.actions.buy ?? (phase == .bonding)) }

    private var trades: [StellarLaunchTrade] {
        (detail?.trades ?? []).sorted { (StellarFormat.date($0.ts) ?? .distantPast) > (StellarFormat.date($1.ts) ?? .distantPast) }
    }

    // MARK: Body

    var body: some View {
        List {
            headerSection
            statsSection
            chartSection
            // No ticket or graduation while neither the coin's row nor its state is read: its phase isn't known yet.
            switch phase {
            case .bonding?: ticketSection
            case .refund?: refundSection
            case .graduating?, .delayed?, .graduated?: graduationSection
            case nil: EmptyView()
            }
            if tokenBalance > 0 { holdingsSection }
            if let rewards = state?.rewards, rewards.sharing { rewardsSection(rewards) }
            feesSection
            if !trades.isEmpty { tradesSection }
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: symbol.isEmpty ? "" : "$\(symbol)"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reloads += 1 }
        // The store too: a page opened before the session has one (a Stellar destination at a cold start) reads once it
        // does.
        .task(id: Reading(reloads: reloads, store: store.map(ObjectIdentifier.init))) { await load() }
        // A new coin's page reads it again until its row exists (`awaitingRow`).
        .task(id: "\(awaitingRow)-\(reloads)") { await waitForRow() }
        // The launch's state too: an amount typed before it was read is quoted once it is.
        .task(id: "\(tradeSide)-\(amountUnits)-\(reloads)-\(stateRead)") { await requote() }
        .sheet(item: $review) { review in confirmation(review) }
        .sheet(isPresented: $changingRecipient) {
            if let launches, let state {
                StellarRecipientChangeSheet(launches: launches, token: token, symbol: symbol, state: state) { reloads += 1 }
            }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    // The coin's own launch art, in the round logo disc every Stellar logo sits in (DyorKit's lint keeps
                    // symbol-keyed logos off the app's screens).
                    StellarLogoDisc(size: 48) { StellarArtwork(symbol: symbol, image: coin?.image, pointSize: 48) }
                    VStack(alignment: .leading, spacing: 2) {
                        // The token's address while its row is unread, never a blank title.
                        Text(verbatim: coin?.name ?? StellarAccountID(token)?.short ?? token).font(.title3.weight(.semibold))
                        Text(verbatim: statusLine).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: priceText)
                            .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                        if let usd = coin?.priceUsd {
                            Text(PriceFormat.usdPrice(usd)).font(.footnote).foregroundStyle(.secondary).monospacedDigit().accessibilityLabel(PriceFormat.spoken(usd))
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: marketCapText).monospacedDigit().fontWeight(.medium)
                        if let usd = coin?.marketCapUsd { Text(PriceFormat.usdValue(usd)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        else { Text("Market cap").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if phase == .bonding, let coin {
                    Gauge(value: progress) {
                        Text("Graduation")
                    } currentValueLabel: {
                        Text(verbatim: "\(percent)%")
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    Paragraph("Graduates at \(StellarFormat.units(coin.threshold, compact: true)) \(quoteCode) raised. Liquidity then moves to a locked \(venueName) pool.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            if AppNetwork.stellar.isTestnet {
                Paragraph(LocalizedStringResource("Dollar values use mainnet market prices. Testnet assets have no value.", table: "StellarLaunch", comment: "Under a Stellar coin's price on its page: its dollar figures come from real mainnet prices of its quote asset, while testnet coins themselves are worth nothing"))
            }
        }
    }

    /// The phase, as the board's badges and Monad's header word it, and the retired launchpad's mark; "—" until the
    /// coin's row or its state is read.
    private var statusLine: String {
        let title: String
        switch phase {
        case nil: return "—"
        case .bonding: title = LaunchPhase.bonding.title
        case .graduating: title = liteTr(LocalizedStringResource("Graduating", table: "StellarLaunch", comment: "[tight] A Stellar launch's phase: its curve is full and it graduates into its pool within minutes"))
        case .delayed: title = liteTr(StellarLaunchWords.graduationDelayed)
        case .graduated: title = LaunchPhase.graduated.title
        case .refund: title = LaunchPhase.refund.title
        }
        return isRetired ? "\(title) · \(tr("Retired launchpad"))" : title
    }

    // MARK: Stats

    private var statsSection: some View {
        Section {
            HStack(spacing: 0) {
                stat("24h Volume", volumeText)
                Divider().frame(height: 34)
                stat("Holders", holders.text)
                Divider().frame(height: 34)
                stat("Progress", coin == nil ? "—" : "\(percent)%")
            }
            if awaitingRow {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            }
            if stateUnread {
                HStack(alignment: .firstTextBaseline) {
                    InlineError(message: "Some details of this launch couldn't be read just now.")
                    Spacer(minLength: 8)
                    Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                }
            }
            if detailUnread {
                HStack(alignment: .firstTextBaseline) {
                    // With no board row either, the page has none of the coin's own figures: its name and ticker included.
                    if coin == nil {
                        InlineError(message: LocalizedStringResource("This coin couldn't be read just now.", table: "StellarLaunch", comment: "On a Stellar coin's page, with Retry: its name, price and other figures couldn't be read"))
                    } else {
                        InlineError(message: "This coin's trades couldn't be read just now.")
                    }
                    Spacer(minLength: 8)
                    Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                }
            }
            if holders.incomplete {
                Paragraph(LocalizedStringResource("Counted from this coin's transfers we've read, so there may be more holders.", table: "StellarLaunch", comment: "Under a Stellar coin's holder count shown as a minimum (“5+”): some of its transfers couldn't be read yet"))
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

    // MARK: Chart

    private var chartSection: some View {
        Section {
            if detail != nil, quoteUSD == nil {
                HStack(alignment: .firstTextBaseline) {
                    InlineError(message: LocalizedStringResource("Prices couldn't be read just now.", table: "StellarLaunch", comment: "On a Stellar coin's page, instead of its chart: the dollar price of the asset it's priced in couldn't be read"))
                    Spacer(minLength: 8)
                    Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                }
            } else {
                StellarPriceChart(points: priceSeries, isLoading: detail == nil && !detailUnread, tint: chartTint)
                    .frame(height: 180)
                    .padding(.vertical, 4)
                    .accessibilityLabel(phase == .graduated
                        ? Text("Price from curve trades and the \(venueName) pool", tableName: "StellarLaunch", comment: "VoiceOver: a graduated Stellar coin's price chart, drawn from its curve's trades and then its pool's. The value is the venue's name (Soroswap)")
                        : Text("Price from curve trades"))
            }
        } header: {
            Text("Price")
        } footer: {
            if detail != nil, detail?.trades.isEmpty == true, phase == .bonding {
                Paragraph("No trades yet — the chart moves up as people buy on the curve and down as they sell.").font(.caption)
            }
        }
    }

    private var priceSeries: [PricePoint] {
        guard let unit = quoteUSD else { return [] }
        return Self.priceSeries(detail?.pricePoints ?? [], current: coin?.priceQuote.flatMap(Double.init), launchedAt: coin.flatMap { StellarFormat.date($0.createdAt) },
                                quoteUSD: unit)
    }

    /// The coin's price line in dollars (each point × the quote's dollar price), ending on the live price; with fewer than
    /// two points, a launch-time baseline first, so a coin with no trades draws a flat line. Only real prices are drawn,
    /// oldest first: a point with no price, or a zero one, is left out, and points that share a time (the launch's opening
    /// price and the developer buy in the same ledger, a trade at the very instant read as the live price) are one point,
    /// the last of them, so the line never runs straight up the edge and its fill is never cut. Sequential ids keep the
    /// points distinct.
    static func priceSeries(_ prices: [StellarLaunchDetail.Point], current: Double?, launchedAt: Date?, quoteUSD unit: Double,
                            now: Date = Date()) -> [PricePoint] {
        guard unit.isFinite, unit > 0 else { return [] }
        var samples: [(time: Date, usd: Double)] = []
        for point in prices {
            guard let time = StellarFormat.date(point.t), let value = Double(point.price), value.isFinite, value > 0 else { continue }
            samples.append((time, value * unit))
        }
        let live = current.flatMap { $0.isFinite && $0 > 0 ? $0 * unit : nil }
        // The live price is now, never before a point read: a clock behind the server's doesn't send the line back.
        if let live { samples.append((max(now, samples.map(\.time).max() ?? now), live)) }
        // Oldest first, in the order read among equal times; then one point per time, the last read.
        let ordered = samples.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        var line: [(time: Date, usd: Double)] = []
        for sample in ordered {
            if let last = line.last, sample.time.timeIntervalSince(last.time) < 1 { line[line.count - 1] = sample } else { line.append(sample) }
        }
        if line.count == 1, let live, let only = line.first {
            let start = min(launchedAt ?? now, only.time.addingTimeInterval(-60))
            line.insert((start, live), at: 0)
        }
        return line.enumerated().map { PricePoint(block: UInt64($0.offset), time: $0.element.time, usd: $0.element.usd) }
    }

    private var chartTint: Color {
        let series = priceSeries
        guard let first = series.first?.usd, let last = series.last?.usd, first != last else { return Color.brand }
        return last >= first ? Color.positive : Color.negative
    }

    // MARK: Ticket

    private var ticketSection: some View {
        Section {
            if buysOpen {
                Picker("Side", selection: $side) {
                    Text("Buy").tag(Side.buy)
                    Text("Sell").tag(Side.sell)
                }
                .pickerStyle(.segmented)
            } else if isRetired {
                Label {
                    Paragraph(LocalizedStringResource("This coin is on DyorHQ's retired launchpad: you can sell it on its curve and claim its fees. New buys are closed.", table: "StellarLaunch", comment: "On a Stellar coin of the retired launchpad (v1), above its ticket: only selling and claiming remain. DyorHQ is never translated"))
                } icon: {
                    Image(systemName: "arrow.up.right.circle")
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            StellarAmountField(title: "0" as String, text: $amountText, code: side == .buy && buysOpen ? quoteCode : symbol) {
                amountText = StellarFormat.plain(units: maxUnits)
            }
            quoteRows
            PrimaryButton(title: tradeTitle, isDisabled: amountUnits == 0 || !canAct || !tradeReady || shortfall != nil) {
                review = .trade
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text(buysOpen ? "Trade on the Curve" : "Sell on the Curve")
        } footer: {
            if let shortfall { Paragraph(verbatim: shortfall).foregroundStyle(Color.attention) }
            else if store?.account != nil {
                Paragraph("Balance: \(StellarFormat.units(tokenBalance, compact: true)) \(symbol) · \(StellarFormat.units(quoteBalance)) \(quoteCode)")
            }
        }
        .onChange(of: buysOpen, initial: true) { _, open in if !open { side = .sell } }
    }

    /// "Buy PEPE" or "Sell PEPE"; without the ticker while the coin's row is unread.
    private var tradeTitle: LocalizedStringKey {
        let buying = side == .buy && buysOpen
        if symbol.isEmpty { return buying ? "Buy" : "Sell" }
        return buying ? "Buy \(symbol)" : "Sell \(symbol)"
    }

    /// What the trade's review needs: the quote for this amount, and on launchpad v2 the launch's state it trades on (a
    /// retired launch's sale needs only its quote).
    private var tradeReady: Bool { isRetired ? retiredQuote != nil : quote != nil && state != nil }

    /// Max: a buy with XLM keeps back the network fee and the minimum balance (§4.5); a buy with any other asset its
    /// balance; a sale the coins held.
    private var maxUnits: Int64 {
        guard let store else { return 0 }
        if side == .buy, buysOpen { return store.maxAmount(asset: quoteIsXLM ? "XLM" : quoteID, stepKind: "launch_buy") }
        return tokenBalance
    }

    /// The fees of the quote, apart (from the curve's own breakdown).
    @ViewBuilder private var quoteRows: some View {
        if let quote, amountUnits > 0 {
            let q = quote.quote
            if quote.side == .buy {
                DetailRow("You receive", verbatim: "\(StellarFormat.units(quote.out, compact: true)) \(symbol)")
                DetailRow("Curve fee", verbatim: StellarFormat.amount(LaunchV2Quote.units(q.baseFee), code: quoteCode))
                if LaunchV2Quote.units(q.creatorFee) > 0 { DetailRow("Creator tax", verbatim: StellarFormat.amount(LaunchV2Quote.units(q.creatorFee), code: quoteCode)) }
                if LaunchV2Quote.units(q.snipeFee) > 0 { DetailRow("Early-buy tax", verbatim: StellarFormat.amount(LaunchV2Quote.units(q.snipeFee), code: quoteCode), tint: Color.attention) }
                if LaunchV2Quote.units(q.refund) > 0 { DetailRow("Refunded (curve full)", verbatim: StellarFormat.amount(LaunchV2Quote.units(q.refund), code: quoteCode)) }
            } else {
                DetailRow("You receive", verbatim: StellarFormat.amount(quote.out, code: quoteCode))
                if quote.side == .sell {
                    DetailRow("Curve fee", verbatim: StellarFormat.amount(LaunchV2Quote.units(q.baseFee), code: quoteCode))
                    if LaunchV2Quote.units(q.creatorFee) > 0 { DetailRow("Creator tax", verbatim: StellarFormat.amount(LaunchV2Quote.units(q.creatorFee), code: quoteCode)) }
                }
            }
        } else if let retiredQuote, amountUnits > 0 {
            DetailRow("You receive", verbatim: StellarFormat.amount(retiredQuote.out, code: quoteCode))
            DetailRow("Curve fee", verbatim: StellarFormat.amount(LaunchV2Quote.units(retiredQuote.quote.baseFee), code: quoteCode))
            if LaunchV2Quote.units(retiredQuote.quote.creatorFee) > 0 {
                DetailRow("Creator tax", verbatim: StellarFormat.amount(LaunchV2Quote.units(retiredQuote.quote.creatorFee), code: quoteCode))
            }
        }
        if let quoteError, amountUnits > 0 { InlineError(message: quoteError) }
    }

    /// Why the trade can't go ahead on this balance: more XLM than the account can spend and stay open, more of another
    /// asset than it holds, or more coins than it holds. Nil while the balances are unknown.
    private var shortfall: String? {
        guard let store, store.account != nil, amountUnits > 0 else { return nil }
        if side == .buy, buysOpen {
            if quoteIsXLM {
                let spendable = store.maxAmount(asset: "XLM", stepKind: "launch_buy")
                guard amountUnits > spendable else { return nil }
                return liteTr(LocalizedStringResource("Not enough XLM: you can spend \(StellarFormat.units(spendable)). The rest keeps your account open and pays the network fee.", table: "StellarLaunch", comment: "Under a Stellar curve buy with XLM, when the amount is more than the account can spend. The value is an amount of XLM. XLM is never translated"))
            }
            guard amountUnits > quoteBalance else { return nil }
            return tr("Not enough \(quoteCode): you have \(StellarFormat.units(quoteBalance)).")
        }
        guard amountUnits > tokenBalance else { return nil }
        return tr("Not enough \(symbol): you have \(StellarFormat.units(tokenBalance, compact: true)).")
    }

    // MARK: Refunds (O2)

    private var refundSection: some View {
        Section {
            if let refund = state?.status.refund {
                Paragraph(LocalizedStringResource("Refund at a fixed \("\(Self.rate(refund.rate)) \(quoteCode)") per token, no fees, any time.", table: "StellarLaunch", comment: "A rescued Stellar launch's refund ticket: every holder gives back coins for the same fixed amount of the quote asset per coin, with no fees and no deadline. The value is that amount with its asset (0.000000048 XLM)"))
                    .font(.subheadline)
            }
            StellarAmountField(title: "0" as String, text: $amountText, code: symbol) { amountText = StellarFormat.plain(units: tokenBalance) }
            if let quote, quote.side == .refund, amountUnits > 0 {
                DetailRow("You receive", verbatim: StellarFormat.amount(quote.out, code: quoteCode))
            }
            if let quoteError, amountUnits > 0 { InlineError(message: quoteError) }
            PrimaryButton(title: Text(symbol.isEmpty ? StellarLaunchWords.refundConfirm : StellarLaunchWords.refund(symbol)),
                          isDisabled: amountUnits == 0 || !canAct || quote == nil || shortfall != nil || state?.status.actions.refund != true) {
                review = .trade
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text(verbatim: LaunchPhase.refund.title)
        } footer: {
            if let shortfall { Paragraph(verbatim: shortfall).foregroundStyle(Color.attention) }
            else {
                Paragraph(LocalizedStringResource("Graduation didn't happen in time, so the curve's funds are shared out: each coin you give back is burned and pays the same amount to every holder, whatever the order.", table: "StellarLaunch", comment: "Footer of a rescued Stellar launch's refund ticket: why refunds are open and that every holder gets the same rate"))
            }
        }
    }

    /// A refund rate (quote per whole coin, human units) as the app writes small numbers.
    private static func rate(_ text: String) -> String {
        Double(text).map { NumberStyle.number($0) } ?? text
    }

    // MARK: Graduation

    private var graduationSection: some View {
        Section {
            switch phase {
            case .graduated:
                Button {
                    router.openStellarSwap(sell: quoteID, buy: token)
                } label: {
                    Label("Swap \(symbol) on \(venueName)", systemImage: "arrow.left.arrow.right")
                }
                LabeledContent("Pool fee", value: coin?.poolFeeBps.map { NumberStyle.basisPoints($0) } ?? "—")
            case .delayed:
                delayedRows
            default:
                if Self.offersGraduate(retired: isRetired, status: state?.status) {
                    Button("Graduate", systemImage: "arrow.up.forward.circle") { Haptics.tap(); review = .graduate(fallback: false) }
                        .disabled(!canAct)
                }
                if state?.status.actions.markStuck == true {
                    Button {
                        review = .markStuck
                    } label: {
                        Label { Text(StellarLaunchWords.markDelayed) } icon: { Image(systemName: "clock.badge.exclamationmark") }
                    }
                    .disabled(!canAct)
                }
            }
        } header: {
            switch phase {
            case .graduated: Text("Graduated")
            case .delayed: Text(StellarLaunchWords.graduationDelayed)
            default: Text("Graduation Pending")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                switch phase {
                case .graduated:
                    Paragraph(LocalizedStringResource("The curve's liquidity is locked forever in a \(venueName) pool. Trades now route through Swap.", table: "StellarLaunch", comment: "Footer of a graduated Stellar coin's section. The value is the venue's name (Soroswap)"))
                    if isRetired {
                        Paragraph(LocalizedStringResource("The pool's fee stays with the pool; no creator tax is charged after graduation.", table: "StellarLaunch", comment: "Footer of a graduated Stellar coin of the retired launchpad (v1): its pool's fees aren't shared out"))
                    } else {
                        Paragraph(harvestCopy)
                    }
                case .delayed:
                    Paragraph(LocalizedStringResource("The last graduation attempt failed. Anyone can retry it and pay only the network fee. If it keeps failing, the fallback venue opens, and then refunds at one fixed rate for every holder.", table: "StellarLaunch", comment: "Footer of a Stellar coin whose graduation is delayed: what happens next, in order"))
                default:
                    Paragraph(LocalizedStringResource("The curve is full. It graduates next, into a \(venueName) pool with its liquidity locked forever, and then trades on Swap. DyorHQ graduates it within a few minutes, or you can do it now and pay only the network fee.", table: "StellarLaunch", comment: "Footer of a Stellar coin whose curve is full and waits to graduate. The value is the venue's name (Soroswap). DyorHQ is never translated"))
                }
            }
        }
    }

    /// The pool fees after graduation, verbatim from §21 with this coin's figures (O1, F1, V2); a figure not read yet
    /// reads "—".
    private var harvestCopy: LocalizedStringResource {
        let pool = coin?.poolFeeBps.map { NumberStyle.basisPoints($0) } ?? "—"
        let share = coin?.protocolShareBps
        let dyorHQ = share.map { NumberStyle.basisPoints($0) } ?? "—"
        let holders = share.map { NumberStyle.basisPoints(10_000 - $0) } ?? "—"
        return LocalizedStringResource("\(pool) pool fee on DyorHQ's locked liquidity, collected hourly, in both \(quoteCode) and \(symbol). Each is split \(dyorHQ) DyorHQ, \(holders) holders or creator. No creator fee after graduation. DyorHQ keeps the \(symbol) it collects; it earns no holder rewards and isn't sold automatically.", table: "StellarLaunch", comment: "A graduated Stellar coin: what happens to its pool's fees. Values in order: the pool fee (0.3%), the quote asset (XLM), the coin's ticker, DyorHQ's share (50%), the holders' or creator's share (50%), the coin's ticker. DyorHQ is never translated")
    }

    /// A delayed graduation (V10): why, since when, when the fallback opens and when refunds can be opened (by DyorHQ's
    /// admin, then by anyone), and what can be done now.
    @ViewBuilder private var delayedRows: some View {
        if let status = state?.status {
            if let failure = status.failure {
                LabeledContent {
                    Text(verbatim: failure.name.map { name in failure.contract.map { "\(name) · \($0)" } ?? name } ?? "\(failure.origin):\(failure.code)")
                        .textSelection(.enabled)
                } label: {
                    Text("Reason", tableName: "StellarLaunch", comment: "On a Stellar coin whose graduation is delayed: the label of why the last attempt failed (an error's name and the contract that raised it)")
                }
            }
            if let since = status.stuckSince.flatMap(StellarFormat.date) {
                LabeledContent("Stuck since", value: since.formatted(date: .abbreviated, time: .shortened))
            }
            if let fallbackAt = status.fallbackAt.flatMap(StellarFormat.date) {
                LabeledContent {
                    Text(fallbackAt <= Date() ? tr("Open") : tr("Opens \(fallbackAt.formatted(date: .abbreviated, time: .shortened))"))
                } label: {
                    Text("Fallback on \(fallbackName)", tableName: "StellarLaunch", comment: "On a Stellar coin whose graduation is delayed: when anyone may graduate it on its fallback venue instead. The value is the venue's name (Soroswap)")
                }
            }
            // The rescue dates: DyorHQ's admin may open refunds first, anyone later.
            let byAnyone = status.rescuePublicAt.flatMap(StellarFormat.date)
            if let byAdmin = status.rescueAdminAt.flatMap(StellarFormat.date), byAnyone.map({ byAdmin < $0 }) ?? true {
                LabeledContent {
                    Text(byAdmin.formatted(date: .abbreviated, time: .shortened))
                } label: {
                    Text("Refunds by DyorHQ from", tableName: "StellarLaunch", comment: "On a Stellar coin whose graduation is delayed: from when DyorHQ's admin may switch it to refunds, before anyone may. DyorHQ is never translated")
                }
            }
            if let byAnyone {
                LabeledContent {
                    Text(byAnyone.formatted(date: .abbreviated, time: .shortened))
                } label: {
                    Text("Refunds by anyone from", tableName: "StellarLaunch", comment: "On a Stellar coin whose graduation is delayed: from when anyone may switch it to refunds")
                }
            }
            if status.actions.graduate {
                Button("Retry Graduation", systemImage: "arrow.clockwise") { review = .graduate(fallback: false) }.disabled(!canAct)
            }
            if status.actions.graduateFallback {
                Button {
                    review = .graduate(fallback: true)
                } label: {
                    Label { Text("Graduate on \(fallbackName)", tableName: "StellarLaunch", comment: "Button on a Stellar coin whose graduation is delayed: graduate it on its fallback venue. The value is the venue's name (Soroswap)") } icon: { Image(systemName: "arrow.triangle.branch") }
                }
                .disabled(!canAct)
            }
            if status.actions.rescue {
                Button {
                    review = .rescue
                } label: {
                    Label { Text(StellarLaunchWords.openRefunds) } icon: { Image(systemName: "arrow.uturn.backward.circle") }
                }
                .disabled(!canAct)
            }
        }
    }

    // MARK: Holdings and rewards

    private var holdingsSection: some View {
        Section("Your Holdings") {
            LabeledContent("Balance") {
                Text(verbatim: "\(StellarFormat.units(tokenBalance, compact: true)) \(symbol)").monospacedDigit()
            }
            LabeledContent("Value") {
                USDText(value: coin?.priceUsd.map { Double(tokenBalance) / 1e7 * $0 })
            }
            LabeledContent("P&L") {
                // Nil in the public view (no session) and for coins received by transfer: unread, never 0.
                if let pnl = detail?.you?.pnlQuote.flatMap({ Int64($0) }) {
                    Text(verbatim: "\(pnl < 0 ? "−" : "+")\(StellarFormat.units(pnl == .min ? .max : abs(pnl))) \(quoteCode)")
                        .monospacedDigit()
                        .foregroundStyle(pnl < 0 ? Color.negative : Color.positive)
                } else {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Holder rewards (L13, F1): pending in the quote and, after graduation, in the coin itself; queued ones are
    /// claimable from the next ledger.
    private func rewardsSection(_ rewards: StellarLaunchStateV2.Rewards) -> some View {
        let pendingQuote = Int64(rewards.pendingQuote ?? "") ?? 0
        let pendingToken = Int64(rewards.pendingToken ?? "") ?? 0
        let queuedQuote = Int64(rewards.queuedQuote) ?? 0
        let queuedToken = Int64(rewards.queuedToken) ?? 0
        return Section {
            if rewards.pendingQuote != nil {
                LabeledContent("Pending rewards") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: StellarFormat.amount(pendingQuote, code: quoteCode)).monospacedDigit()
                        if rewards.pendingToken != nil, phase == .graduated || pendingToken > 0 {
                            Text(verbatim: "\(StellarFormat.units(pendingToken, compact: true)) \(symbol)").monospacedDigit()
                        }
                    }
                }
            }
            if queuedQuote > 0 || queuedToken > 0 {
                LabeledContent("Queued for holders") {
                    Text(verbatim: queuedToken > 0
                         ? "\(StellarFormat.amount(queuedQuote, code: quoteCode)) · \(StellarFormat.units(queuedToken, compact: true)) \(symbol)"
                         : StellarFormat.amount(queuedQuote, code: quoteCode))
                        .monospacedDigit()
                }
            }
            if pendingQuote > 0 || pendingToken > 0 {
                Button("Claim Rewards", systemImage: "gift") { Haptics.tap(); review = .claimRewards }.disabled(!canAct)
            }
        } header: {
            Text("Holder rewards")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if queuedQuote > 0 || queuedToken > 0 {
                    Paragraph(LocalizedStringResource("Queued rewards are claimable from the next ledger.", table: "StellarLaunch", comment: "Under a Stellar coin's holder rewards: rewards just paid in are shared out a few seconds later, from the network's next ledger"))
                }
                Paragraph(LocalizedStringResource("Holders also earn part of the pool fees after graduation, in this coin and in \(quoteCode).", table: "StellarLaunch", comment: "Under a Stellar coin's holder rewards, and the Share fees with holders setting: after graduation holders also get part of the pool's fees, in the coin and in its quote asset. The value is the quote asset (XLM)"))
                Paragraph(LocalizedStringResource("DEX pools of this coin are excluded from holder rewards once DyorHQ verifies them. Other contracts that hold the coin, such as lending markets and vaults, keep earning rewards that only they can claim.", table: "StellarLaunch", comment: "Under a Stellar coin's holder rewards: which holders don't earn them. DyorHQ is never translated"))
            }
        }
    }

    // MARK: Creator fees

    /// Always shown, as on Monad: the creator tax and fee share, the fee recipient (and a pending takeover with its
    /// veto), the recipient's claimable fees and the viewer's owed fees from before a change.
    private var feesSection: some View {
        Section {
            LabeledContent("Creator tax", value: creatorTaxText)
            if let feeBps = coin?.feeBps, let protocolShareBps = coin?.protocolShareBps {
                LabeledContent {
                    Text(verbatim: NumberStyle.basisPoints(feeBps * (10_000 - protocolShareBps) / 10_000))
                } label: {
                    Text("Curve fee share", tableName: "StellarLaunch", comment: "On a Stellar coin's page, creator fees: the part of every curve trade's fee that goes to the creator (or to holders when fee sharing is on), as a percent of the trade")
                }
            }
            if let recipient = StellarAccountID(state?.recipient ?? coin?.creator ?? "") {
                StellarAddressRow(title: "Fee recipient", address: recipient)
            }
            if let takeover = state?.pendingTakeover { takeoverRows(takeover) }
            if state?.you?.isRecipient == true || (isRetired && detail?.you?.isCreator == true) {
                let claimable = claimableFees
                if claimable > 0 {
                    LabeledContent("Your claimable fees") {
                        Text(verbatim: StellarFormat.amount(claimable, code: quoteCode)).monospacedDigit().fontWeight(.semibold).foregroundStyle(Color.brand)
                    }
                    Button("Claim Creator Fees", systemImage: "banknote") { Haptics.tap(); review = .claimCreator }.disabled(!canAct)
                } else if state?.rewards.sharing != true {
                    // With sharing on the creator's part goes to holders, so nothing ever waits here.
                    Paragraph("Nothing to claim yet — fees accrue as people trade your coin.").font(.caption).foregroundStyle(.secondary)
                }
                if state?.you?.isRecipient == true, phase != .refund {
                    Button {
                        changingRecipient = true
                    } label: {
                        Label { Text(StellarLaunchWords.changeRecipient) } icon: { Image(systemName: "arrow.left.arrow.right.circle") }
                    }
                    .disabled(!canAct)
                }
            }
            if let owed = owedFees, owed > 0 {
                LabeledContent {
                    Text(verbatim: StellarFormat.amount(owed, code: quoteCode)).monospacedDigit()
                } label: {
                    Text("Owed to you", tableName: "StellarLaunch", comment: "On a Stellar coin's page: the creator fees the viewer earned before its fee recipient changed, still to be claimed")
                }
                Button {
                    Haptics.tap()
                    review = .claimOwed
                } label: {
                    Label { Text(StellarLaunchWords.claimOwed) } icon: { Image(systemName: "banknote") }
                }
                .disabled(!canAct)
            }
        } header: {
            Text("Creator Fees")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                switch sharesFees {
                case true?:
                    Paragraph(LocalizedStringResource("With fee sharing on, the creator tax and the creator's share of the curve fee go to holders as rewards.", table: "StellarLaunch", comment: "Footer of a Stellar coin's creator fees, when it shares its fees with holders"))
                case false?:
                    Paragraph(LocalizedStringResource("The creator earns the creator tax plus a share of the \(coin?.feeBps.map { NumberStyle.basisPoints($0) } ?? "—") curve fee on every curve trade. Fees wait in the launchpad until the creator claims them.", table: "StellarLaunch", comment: "Footer of a Stellar coin's creator fees. The value is the curve fee as a percent (1%)"))
                case nil:
                    EmptyView()
                }
                if state?.pendingTakeover != nil || (owedFees ?? 0) > 0 {
                    Paragraph(StellarLaunchWords.feesStay)
                }
            }
        }
    }

    /// Whether the coin shares its fees with holders: v2's state says (nil until it is read); a retired launch never does.
    private var sharesFees: Bool? { isRetired ? false : state?.rewards.sharing }

    /// The creator tax, "—" until the coin is read.
    private var creatorTaxText: String { coin?.creatorFeeBps.map { NumberStyle.basisPoints($0) } ?? "—" }

    /// The recipient's claimable fees: v2's booked curve fees, or a retired launch's unclaimed ones.
    private var claimableFees: Int64 {
        if let state { return Int64(state.creatorFees) ?? 0 }
        return detail?.creatorFees.flatMap { Int64($0.unclaimed) } ?? 0
    }

    private var owedFees: Int64? { state?.you.flatMap { Int64($0.creatorOwed) } }

    /// The admin's pending takeover of the fee recipient: who, when, and the current recipient's veto while it waits.
    @ViewBuilder private func takeoverRows(_ takeover: StellarLaunchStateV2.Takeover) -> some View {
        let now = Date()
        let open = takeover.state(at: now)
        if open != "lapsed", let proposed = StellarAccountID(takeover.new) {
            StellarAddressRow(resource: StellarLaunchWords.proposedRecipient, address: proposed)
            if let effective = StellarFormat.date(takeover.effectiveAt) {
                LabeledContent {
                    Text(effective.formatted(date: .abbreviated, time: .shortened))
                } label: {
                    Text("Takes effect", tableName: "StellarLaunch", comment: "On a Stellar coin's page: from when a proposed change of its fee recipient can be applied")
                }
            }
            if state?.you?.isRecipient == true {
                Button(role: .destructive) {
                    review = .recipient(.cancel)
                } label: {
                    Label { Text("Veto", tableName: "StellarLaunch", comment: "[tight] Button on a Stellar coin's page, for its fee recipient: refuse a proposed change of the account that receives its creator fees") } icon: { Image(systemName: "hand.raised") }
                }
                .disabled(!canAct)
            }
            if open == "open" {
                Button {
                    review = .recipient(.execute)
                } label: {
                    Label { Text(StellarLaunchWords.applyChange) } icon: { Image(systemName: "checkmark.circle") }
                }
                .disabled(!canAct)
            }
        }
    }

    // MARK: Trades and about

    private var tradesSection: some View {
        Section("Recent Trades") {
            ForEach(Array(trades.prefix(25).enumerated()), id: \.offset) { _, trade in
                StellarLaunchTradeRow(trade: trade, symbol: symbol, quoteCode: quoteCode)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            if let description = coin?.description, !description.isEmpty { Paragraph(verbatim: description).font(.subheadline) }
            if let address = StellarAccountID(token) { StellarAddressRow(title: "Token", address: address) }
            if let creator = coin.flatMap({ StellarAccountID($0.creator) }) { StellarAddressRow(title: "Creator", address: creator) }
            LabeledContent("Creator tax", value: creatorTaxText)
            LabeledContent {
                Text(verbatim: quoteCode)
            } label: {
                Text("Priced in", tableName: "StellarLaunch", comment: "On a Stellar coin's page, About: the asset its curve is priced in (XLM, USDC)")
            }
            if !isRetired, let state {
                LabeledContent("Holder fee sharing", value: state.rewards.sharing ? tr("On") : tr("Off"))
            }
            LabeledContent("Graduation venue", value: venueName)
            if let totalSupply {
                LabeledContent {
                    Text(verbatim: "\(StellarFormat.units(totalSupply, compact: true)) \(symbol)").monospacedDigit()
                } label: {
                    Text("Total supply", tableName: "StellarLaunch", comment: "On a Stellar coin's page, About: how many of its coins exist (its supply less every burn)")
                }
            }
            if let fdvQuote {
                LabeledContent("FDV") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: "\(NumberStyle.number(fdvQuote, compact: true)) \(quoteCode)").monospacedDigit()
                        if let quoteUSD { Text(PriceFormat.usdValue(fdvQuote * quoteUSD)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
            }
            ForEach(socialLinks, id: \.0) { label, url in
                Link(destination: url) { Label(label, systemImage: "link") }
            }
            if let page = StellarExplorer.contract(token, network: LiteGate.pinned.network) {
                Link(destination: page) {
                    Label {
                        Text("View on StellarExpert", tableName: "StellarCommon", comment: "A menu item and a link: opens this address, contract or transaction on StellarExpert, a Stellar block explorer. StellarExpert is never translated")
                    } icon: {
                        Image(systemName: "safari")
                    }
                }
            }
        }
    }

    private var socialLinks: [(String, URL)] {
        let links = coin?.links
        // not localized: X and Telegram are the services' own names.
        return [(tr("Website"), links?.website), ("X", links?.x), ("Telegram", links?.telegram)]
            // Creator-set strings: only web links with a host, never another app's URL scheme.
            .compactMap { label, value in
                value.flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host() != nil ? (label, $0) : nil }
            }
    }

    // MARK: Reviews (§8.10.5)

    @ViewBuilder private func confirmation(_ review: Review) -> some View {
        if let launches, let store, !symbol.isEmpty {
            switch review {
            case .trade: tradeConfirmation(launches, store: store)
            case .graduate(let fallback):
                StellarConfirmationSheet(title: LocalizedStringResource("Graduate \(symbol)", table: "StellarLaunch", comment: "Title of the review that graduates a Stellar coin into its pool. The value is the coin's ticker"),
                                         confirmTitle: "Graduate",
                                         build: {
                                             isRetired ? try await store.graduatePlan(token: token)
                                                 : try await launches.graduatePlan(token: token, symbol: symbol, fallback: fallback)
                                         },
                                         onDone: { reloads += 1 }) {
                    DetailRow("Venue", verbatim: fallback ? fallbackName : venueName)
                    DetailRow(Text("Who pays"), Text(StellarLaunchWords.networkFeeOnly))
                }
            case .markStuck:
                StellarConfirmationSheet(title: StellarLaunchWords.markDelayed, confirmTitle: StellarLaunchWords.markDelayed,
                                         build: { try await launches.markStuckPlan(token: token, symbol: symbol) },
                                         onDone: { reloads += 1 }) {
                    DetailRow(Text("Who pays"), Text(StellarLaunchWords.networkFeeOnly))
                }
            case .rescue:
                StellarConfirmationSheet(title: StellarLaunchWords.openRefunds, confirmTitle: StellarLaunchWords.openRefunds,
                                         build: { try await launches.rescuePlan(token: token, symbol: symbol) },
                                         onDone: { reloads += 1 }) {
                    DetailRow(Text("Who pays"), Text(StellarLaunchWords.networkFeeOnly))
                }
            case .claimCreator:
                StellarConfirmationSheet(title: "Claim Creator Fees", confirmTitle: "Claim Fees",
                                         build: {
                                             if isRetired {
                                                 guard let action = try await store.claimPlan(tokens: [token]).first else { throw LiteAPIError.decoding("the claim") }
                                                 return action
                                             }
                                             return try await launches.claimPlan(token: token, symbol: symbol)
                                         },
                                         onDone: { reloads += 1 }) {
                    DetailRow("Claimable", verbatim: StellarFormat.amount(claimableFees, code: quoteCode))
                    DetailRow("To", verbatim: StellarAccountID(state?.recipient ?? coin?.creator ?? "")?.short ?? "—")
                }
            case .claimOwed:
                StellarConfirmationSheet(title: StellarLaunchWords.claimOwed, confirmTitle: "Claim Fees",
                                         build: {
                                             guard let state else { throw LiteAPIError.decoding("the launch") }
                                             return try await launches.claimOwedPlan(asset: state.quote, amount: owedFees ?? 0)
                                         },
                                         onDone: { reloads += 1 }) {
                    DetailRow("Claimable", verbatim: StellarFormat.amount(owedFees ?? 0, code: quoteCode))
                }
            case .claimRewards:
                StellarConfirmationSheet(title: "Claim Rewards", confirmTitle: "Claim",
                                         build: { try await launches.claimRewardsPlan(token: token, symbol: symbol) },
                                         onDone: { reloads += 1 }) {
                    if let rewards = state?.rewards {
                        DetailRow("Pending rewards", verbatim: StellarFormat.amount(Int64(rewards.pendingQuote ?? "") ?? 0, code: quoteCode))
                        if let token = rewards.pendingToken.flatMap({ Int64($0) }), token > 0 {
                            DetailRow("Pending rewards", verbatim: "\(StellarFormat.units(token, compact: true)) \(symbol)")
                        }
                    }
                }
            case .recipient(let change):
                StellarRecipientReview(launches: launches, token: token, symbol: symbol, quoteCode: quoteCode, change: change,
                                       proposed: state?.pendingTakeover?.new) { reloads += 1 }
            }
        }
    }

    @ViewBuilder private func tradeConfirmation(_ launches: LaunchV2Store, store: LiteStore) -> some View {
        if let retiredQuote, isRetired {
            StellarConfirmationSheet(title: "Sell \(symbol)", confirmTitle: "Sell",
                                     build: { try await store.launchTradePlan(token: token, buy: false, amount: retiredQuote.amount, minOut: retiredQuote.minOut) },
                                     onDone: { amountText = ""; reloads += 1 }) {
                DetailRow("You receive", verbatim: StellarFormat.amount(retiredQuote.out, code: quoteCode))
            }
        } else if let quote, let state {
            switch quote.side {
            case .buy:
                StellarConfirmationSheet(title: "Buy \(symbol)", confirmTitle: "Buy",
                                         build: { try await launches.tradePlan(quote, token: token, symbol: symbol, asset: state.quote) },
                                         onDone: { amountText = ""; reloads += 1 }) {
                    DetailRow("You receive", verbatim: "\(StellarFormat.units(quote.out, compact: true)) \(symbol)")
                }
            case .sell:
                StellarConfirmationSheet(title: "Sell \(symbol)", confirmTitle: "Sell",
                                         build: { try await launches.tradePlan(quote, token: token, symbol: symbol, asset: state.quote) },
                                         onDone: { amountText = ""; reloads += 1 }) {
                    DetailRow("You sell", verbatim: "\(StellarFormat.units(quote.amount, compact: true)) \(symbol)")
                    DetailRow("You receive", verbatim: StellarFormat.amount(quote.out, code: quoteCode))
                }
            case .refund:
                StellarConfirmationSheet(title: StellarLaunchWords.refund(symbol), confirmTitle: StellarLaunchWords.refundConfirm,
                                         build: { try await launches.tradePlan(quote, token: token, symbol: symbol, asset: state.quote) },
                                         onDone: { amountText = ""; reloads += 1 }) {
                    DetailRow("You sell", verbatim: "\(StellarFormat.units(quote.amount, compact: true)) \(symbol)")
                    DetailRow("You receive", verbatim: StellarFormat.amount(quote.out, code: quoteCode))
                    DetailRow(Text("Fees"), Text(verbatim: StellarFormat.amount(0, code: quoteCode)))
                }
            }
        }
    }

    // MARK: Reading

    private func load() async {
        guard let store else { return }
        let launches = self.launches.flatMap { $0.store === store ? $0 : nil } ?? LaunchV2Store(store: store)
        self.launches = launches
        async let account: Void = store.refreshAccount()
        async let page = store.launchDetail(token)
        async let live = launches.state(token)
        let justLaunched = Self.justLaunched.contains(token)
        do {
            let read = try await page
            detail = read
            row = read.launch
            detailUnread = false
            awaitingRow = false
            Self.justLaunched.remove(token)
        } catch LiteAPIError.server(404, _, _, _) where Self.waitsForRow(justLaunched: justLaunched, hasRow: coin != nil, waits: rowWaits) {
            // Just launched: the indexer records the coin within seconds, and the page reads it again until it has.
            awaitingRow = true
        } catch {
            // A read cut short because the page went away isn't a failure.
            if !Task.isCancelled {
                awaitingRow = false
                detailUnread = true
            }
        }
        do {
            state = try await live
            stateRead = true
            stateUnread = false
        } catch {
            if !Task.isCancelled { stateUnread = true }
        }
        _ = await account
    }

    /// How many times a coin with no row yet is read again, `rowWait` apart (about two minutes in all).
    static let rowWaitLimit = 30
    static let rowWait: Duration = .seconds(4)

    /// The coins Create launched while the app is open whose page hasn't read their row yet
    /// (`StellarCreateLaunchView.openLaunched`): only their page waits for the indexer to record them.
    static var justLaunched: Set<String> = []

    /// Whether a page read that found no coin waits for the indexer to record it: only for a coin Create just launched,
    /// while the page has no row of it (opened by its token alone) and within `rowWaitLimit` reads. A link or a
    /// notification naming a coin the server doesn't know says so at once.
    static func waitsForRow(justLaunched: Bool, hasRow: Bool, waits: Int) -> Bool {
        justLaunched && !hasRow && waits < rowWaitLimit
    }

    /// While the coin's row is awaited, the page reads it again after `rowWait`.
    private func waitForRow() async {
        guard awaitingRow else { return }
        try? await Task.sleep(for: Self.rowWait)
        guard !Task.isCancelled, awaitingRow else { return }
        rowWaits += 1
        reloads += 1
    }

    /// The trade's price for the amount typed: the previous amount's is dropped first, so the minimum a review signs is
    /// never another amount's (Monad's rule). A changed amount cancels the read under way. Only once the launch's state
    /// was read: it says which launchpad prices the trade, and the review trades on it.
    private func requote() async {
        quote = nil
        retiredQuote = nil
        quoteError = nil
        guard amountUnits > 0, let store, let launches, stateRead else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            if isRetired {
                guard side == .sell || !buysOpen else { return }
                let fresh = try await store.launchQuote(token: token, buy: false, amount: amountUnits)
                if !Task.isCancelled { retiredQuote = fresh }
            } else {
                let fresh = try await launches.quote(token: token, side: tradeSide, amount: amountUnits)
                if !Task.isCancelled { quote = fresh }
            }
        } catch {
            if !Task.isCancelled { quoteError = LiteErrorText.describe(error) }
        }
    }
}

/// One curve or pool trade in the coin's recent trades: buy or sell, the coins, the trader, the quote amount, and when; a
/// tap opens the transaction on StellarExpert.
private struct StellarLaunchTradeRow: View {
    let trade: StellarLaunchTrade
    let symbol: String
    let quoteCode: String

    private var isBuy: Bool { trade.side == "buy" }

    var body: some View {
        Group {
            if let hash = trade.txHash, let page = StellarExplorer.transaction(hash, network: LiteGate.pinned.network) {
                Link(destination: page) { rowContent }.foregroundStyle(.primary)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: isBuy ? "arrow.down.left" : "arrow.up.right")
                .font(.footnote.weight(.bold))
                .frame(width: 30, height: 30)
                .background((isBuy ? Color.positive : Color.negative).opacity(0.14), in: Circle())
                .foregroundStyle(isBuy ? Color.positive : Color.negative)
            VStack(alignment: .leading, spacing: 1) {
                Text(isBuy ? "Buy \(StellarFormat.units(trade.tokenAmount, compact: true)) \(symbol)" : "Sell \(StellarFormat.units(trade.tokenAmount, compact: true)) \(symbol)")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 4) {
                    Text(verbatim: StellarAccountID(trade.trader)?.short ?? trade.trader).monospacedDigit()
                    if trade.venue == "soroswap" { Text(verbatim: "· Soroswap") } // not localized: a venue's name
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: "\(StellarFormat.units(trade.quoteAmount, compact: true)) \(quoteCode)")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                if let time = StellarFormat.date(trade.ts) {
                    Text("\(RelativeTime.short(Int(time.timeIntervalSince1970))) ago").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Monad's `PriceChart` for a launch page: the line and its fill over the plotted price range, the fill anchored at that
/// range's floor (never at zero), the time axis exactly the line's span, and one label per mark at a stride that suits
/// the span, each label distinct (`timeAxis`): a launch an hour or two old reads "6:00 AM, 6:30 AM, 7:00 AM", never
/// "6 AM, 6 AM, 7 AM".
struct StellarPriceChart: View {
    let points: [PricePoint]
    let isLoading: Bool
    let tint: Color
    /// The app's language: a chart draws its axis labels once, so they are formatted in it explicitly, and a change of
    /// language draws them again.
    @Environment(\.locale) private var locale

    /// The plotted range with a little headroom. An area mark anchors at zero by default, which flattens a price line
    /// into a ruler, so the fill starts at this floor instead.
    private var domain: ClosedRange<Double> { Self.domain(points) }

    static func domain(_ points: [PricePoint]) -> ClosedRange<Double> {
        let values = points.map(\.usd)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.08, abs(high) * 0.0005, 1e-12)
        return (low - padding)...(high + padding)
    }

    /// The time axis's marks and their labels' format, for a line from `first` to `last`: about four marks at the first
    /// stride that keeps them to four, on round times (the hour, the half hour, midnight), and a format fine enough that
    /// no two of them read the same (minutes under an hour's stride, the day once the marks span days).
    static func timeAxis(from first: Date, to last: Date, locale: Locale, calendar: Calendar = .current) -> (marks: [Date], format: Date.FormatStyle) {
        let span = max(0, last.timeIntervalSince(first))
        let strides: [(component: Calendar.Component, count: Int, seconds: TimeInterval)] = [
            (.minute, 1, 60), (.minute, 2, 120), (.minute, 5, 300), (.minute, 10, 600), (.minute, 15, 900), (.minute, 30, 1_800),
            (.hour, 1, 3_600), (.hour, 2, 7_200), (.hour, 3, 10_800), (.hour, 6, 21_600), (.hour, 12, 43_200),
            (.day, 1, 86_400), (.day, 2, 172_800), (.day, 7, 604_800), (.day, 14, 1_209_600), (.month, 1, 2_629_746), (.month, 3, 7_889_238),
            (.year, 1, 31_556_952),
        ]
        let stride = strides.first { span / $0.seconds <= 4 } ?? strides[strides.count - 1]
        // The first round time at or after `first`, then every stride to `last`.
        var marks: [Date] = []
        if var mark = Self.roundUp(first, to: stride.component, count: stride.count, calendar: calendar) {
            while mark <= last, marks.count < 32 {
                marks.append(mark)
                guard let next = calendar.date(byAdding: stride.component, value: stride.count, to: mark), next > mark else { break }
                mark = next
            }
        }
        var formats: [Date.FormatStyle] = switch stride.component {
        case .minute: [.dateTime.hour().minute(), .dateTime.month(.abbreviated).day().hour().minute()]
        case .hour: [.dateTime.hour(), .dateTime.month(.abbreviated).day().hour()]
        case .day: [.dateTime.month(.abbreviated).day(), .dateTime.year().month(.abbreviated).day()]
        default: [.dateTime.month(.abbreviated).year(), .dateTime.year().month(.abbreviated).day()]
        }
        formats = formats.map { format in
            var format = format.locale(locale)
            format.timeZone = calendar.timeZone
            return format
        }
        let format = formats.first { format in Set(marks.map { $0.formatted(format) }).count == marks.count } ?? formats[formats.count - 1]
        return (marks, format)
    }

    /// `date` moved forward to the next whole multiple of `count` of `component` (12:00, 12:30, midnight, the 1st).
    private static func roundUp(_ date: Date, to component: Calendar.Component, count: Int, calendar: Calendar) -> Date? {
        let unit: Calendar.Component = switch component {
        case .minute: .hour
        case .hour, .day: .day
        default: .year
        }
        guard let start = calendar.dateInterval(of: unit, for: date)?.start else { return nil }
        var mark = start
        while mark < date {
            guard let next = calendar.date(byAdding: component, value: count, to: mark), next > mark else { return nil }
            mark = next
        }
        return mark
    }

    var body: some View {
        if points.count >= 2, let first = points.first?.time, let last = points.last?.time, first < last {
            let axis = Self.timeAxis(from: first, to: last, locale: locale)
            Chart(points) { point in
                LineMark(x: .value("Time", point.time), y: .value("Price", point.usd))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                AreaMark(x: .value("Time", point.time), yStart: .value("Floor", domain.lowerBound), yEnd: .value("Price", point.usd))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
            }
            .chartXScale(domain: first...last)
            .chartYScale(domain: domain)
            // Centred on their marks: a date label starts at its mark by default, so the last one ran past the plot ("Oc…").
            .chartXAxis { AxisMarks(values: axis.marks) { _ in AxisGridLine(); AxisValueLabel(format: axis.format, centered: true) } }
            .chartYAxis {
                // Labels as fine as the plotted range needs (`PriceFormat.axis`), so a dust coin's ticks don't all read "0".
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel { if let price = value.as(Double.self) { Text(PriceFormat.axis(price, span: domain.upperBound - domain.lowerBound)) } }
                }
            }
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

/// The current fee recipient hands a coin's creator fees to another account: the address, then the review.
private struct StellarRecipientChangeSheet: View {
    let launches: LaunchV2Store
    let token: String
    let symbol: String
    let state: StellarLaunchStateV2
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var addressText = ""
    @State private var reviewing = false

    private var address: StellarAccountID? { StellarAccountID(addressText.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $addressText, prompt: Text(verbatim: "G… / C…")) {
                        Text(StellarLaunchWords.newRecipient)
                    }
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    if !addressText.isEmpty, address == nil {
                        InlineError(message: LocalizedStringResource("That isn't a Stellar address.", table: "StellarLaunch", comment: "Under an address field on Stellar: what was typed isn't a valid G… or C… address. Stellar is a network's name, never translated"))
                    }
                } header: {
                    Text(StellarLaunchWords.newRecipient)
                } footer: {
                    Paragraph(StellarLaunchWords.feesStay)
                }
            }
            .navigationTitle(tr(StellarLaunchWords.changeRecipient))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { Haptics.tap(); reviewing = true }
                        .fontWeight(.semibold)
                        .disabled(address == nil || address?.checksummed == state.recipient)
                }
            }
            .sheet(isPresented: $reviewing) {
                if let address {
                    StellarRecipientReview(launches: launches, token: token, symbol: symbol, quoteCode: state.quote.code,
                                           change: .transfer(to: address.checksummed), proposed: nil) {
                        onDone()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The review of a fee recipient change: the transfer, a veto or an applied takeover. On a graduated coin without holder
/// sharing, the plan first collects the pool fees; what one collection can't take before the change (the backlog) is
/// shown with the choice to wait for the hourly collections instead (V7): Cancel waits, Confirm changes now.
private struct StellarRecipientReview: View {
    let launches: LaunchV2Store
    let token: String
    let symbol: String
    let quoteCode: String
    let change: LaunchV2RecipientChange
    /// The takeover's proposed recipient, for a veto or an apply.
    let proposed: String?
    let onDone: () -> Void
    @State private var backlog: StellarHarvestBacklogV2?

    private var title: LocalizedStringResource {
        switch change {
        case .transfer: StellarLaunchWords.changeRecipient
        case .cancel: LocalizedStringResource("Veto Change", table: "StellarLaunch", comment: "Title of the review in which a Stellar coin's fee recipient refuses a proposed change of that account")
        case .execute: StellarLaunchWords.applyChange
        }
    }

    var body: some View {
        StellarConfirmationSheet(title: title, confirmTitle: title,
                                 build: {
                                     let plan = try await launches.recipientPlan(token: token, symbol: symbol, change: change)
                                     backlog = plan.backlog
                                     return plan.action
                                 },
                                 onDone: onDone) {
            switch change {
            case .transfer(let to):
                if let address = StellarAccountID(to) { DetailRow(Text(StellarLaunchWords.newRecipient), Text(verbatim: address.short)) }
            case .cancel, .execute:
                if let address = proposed.flatMap(StellarAccountID.init) {
                    DetailRow(Text(StellarLaunchWords.proposedRecipient), Text(verbatim: address.short))
                }
            }
            if change != .cancel {
                Paragraph(StellarLaunchWords.feesStay)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let backlog {
                DetailRow(Text("Pool fees not collected yet", tableName: "StellarLaunch", comment: "In the review of a Stellar coin's fee recipient change: the pool fees the hourly collections haven't taken yet, which go to the new recipient"),
                          Text(verbatim: "\(StellarFormat.amount(Int64(backlog.residualQuote) ?? 0, code: quoteCode)) · \(StellarFormat.units(backlog.residualToken, compact: true)) \(symbol)"))
                Paragraph(LocalizedStringResource("Wait about \(Self.hours(until: backlog.drainedBy)) hours for the hourly collections to take it, or change now.", table: "StellarLaunch", comment: "In the review of a Stellar coin's fee recipient change: the uncollected pool fees go to the new recipient unless you wait for the hourly collections. The value is a number of hours; Cancel waits"))
                    .font(.footnote).foregroundStyle(Color.attention)
            }
        }
    }

    /// Whole hours from now until `time` (at least 1).
    private static func hours(until time: String) -> Int {
        guard let date = StellarFormat.date(time) else { return 1 }
        return max(1, Int((date.timeIntervalSinceNow / 3600).rounded(.up)))
    }
}
/// The launch page's words that more than one place shows, written once.
enum StellarLaunchWords {
    static let graduationDelayed = LocalizedStringResource("Graduation delayed", table: "StellarLaunch", comment: "[tight] A Stellar launch's phase: its curve is full but graduating into its pool failed or took too long; retries, a fallback venue and refunds follow")
    static let markDelayed = LocalizedStringResource("Mark as Delayed", table: "StellarLaunch", comment: "Button and review title on a Stellar coin whose full curve hasn't graduated within its grace period: record the delay, which opens its fallback and refund paths")
    static let openRefunds = LocalizedStringResource("Open Refunds", table: "StellarLaunch", comment: "Button and review title on a Stellar coin stuck past its rescue date: switch it to refunds at one fixed rate for every holder")
    static let claimOwed = LocalizedStringResource("Claim Owed Fees", table: "StellarLaunch", comment: "Button and review title on a Stellar coin's page: collect the creator fees earned before its fee recipient changed")
    static let changeRecipient = LocalizedStringResource("Change Fee Recipient", table: "StellarLaunch", comment: "Button, screen and review title on a Stellar coin's page, for the account that receives its creator fees: hand them to another account")
    static let applyChange = LocalizedStringResource("Apply Change", table: "StellarLaunch", comment: "Button and review title on a Stellar coin's page: carry out a proposed change of its fee recipient, now that its waiting time is over")
    static let newRecipient = LocalizedStringResource("New recipient", table: "StellarLaunch", comment: "The account that will receive a Stellar coin's creator fees after a change of its fee recipient")
    static let proposedRecipient = LocalizedStringResource("Proposed recipient", table: "StellarLaunch", comment: "On a Stellar coin's page: the account DyorHQ's admin proposed to receive its creator fees, a change the current recipient can veto. DyorHQ is never translated")
    static let networkFeeOnly = LocalizedStringResource("You (network fee only)", table: "StellarLaunch", comment: "In the review that graduates, marks or rescues a Stellar coin, as who pays: anyone may, and the user pays only the network fee")
    static let refundConfirm = LocalizedStringResource("Refund", table: "StellarLaunch", comment: "[tight] The button of a rescued Stellar launch's refund ticket, and the confirm button of its review: give back coins at the fixed rate")
    static let feesStay = LocalizedStringResource("Curve fees earned so far stay with the current recipient. Pool fees not yet collected go to the new one.", table: "StellarLaunch", comment: "On a Stellar coin's page and in the review of a fee recipient change: what a change of the account that receives creator fees does to fees already earned")

    static func refund(_ symbol: String) -> LocalizedStringResource {
        LocalizedStringResource("Refund \(symbol)", table: "StellarLaunch", comment: "Button and review title on a rescued Stellar launch's page: give back coins at the fixed refund rate. The value is the coin's ticker")
    }
}
#endif
