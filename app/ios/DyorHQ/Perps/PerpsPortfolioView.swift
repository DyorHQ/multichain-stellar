import DyorKit
import SwiftUI

/// The perps portfolio: live account value from the on-chain account, and cumulative volume, realized P&L, fees,
/// win rate and a trade log from Perpl's authenticated history API. The live figures move with the market-data feed
/// via the shared `PerpsModel`; the history is signed with the account's API key and refreshed on open and on pull.
struct PerpsPortfolioView: View {
    let model: PerpsModel
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(\.dismiss) private var dismiss
    @State private var portfolio = PerpsPortfolioModel()
    @State private var tab: HistoryTab = .fills
    /// When the history was last read, and the read the live stream asked for while one was too recent.
    @State private var historyReadAt: Date = .distantPast
    @State private var historyReload: Task<Void, Never>?
    /// The live stream's fills read the history again at most this often (each read is several signed pages).
    private static let historySpacing: TimeInterval = 5

    // The raw values are identifiers; each tab's name on screen is its `title`.
    enum HistoryTab: String, CaseIterable, Identifiable {
        case fills = "Fills", closed = "Closed" // not localized: identifiers
        var id: String { rawValue }
        var title: Text {
            switch self {
            case .fills: Text("Fills", comment: "A tab of the Perps portfolio: the account's executed trades (a noun). [tight]")
            case .closed: Text("Closed", comment: "A tab of the Perps portfolio: the account's closed positions. [tight]")
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    accountCard
                    statsGrid
                    historyCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(tr("Portfolio"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await loadHistory() }
            .task { await loadHistory() }
            // A fill or a position change on the live trading stream: the history reads again (at most every 5 s).
            .onChange(of: perplTrading.historyRevision) { _, _ in reloadHistorySoon() }
        }
    }

    private func loadHistory() async {
        historyReadAt = Date()
        await portfolio.load(env: env, key: perplTrading.key, markets: model.markets)
    }

    /// One read for any number of the stream's requests: now, or 5 s after the last read.
    private func reloadHistorySoon() {
        guard historyReload == nil else { return }
        let wait = Self.historySpacing - Date().timeIntervalSince(historyReadAt)
        historyReload = Task { @MainActor in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            await loadHistory()
            historyReload = nil
        }
    }

    // MARK: Account value

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account Value").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                USDText(value: model.equity, font: .system(.largeTitle, design: .rounded).weight(.semibold))
                if model.unrealizedTotal != 0 {
                    Text(PriceFormat.usdValue(model.unrealizedTotal, signed: true))
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                        .foregroundStyle(model.unrealizedTotal < 0 ? Color.negative : Color.positive)
                }
            }
            Divider()
            HStack {
                miniStat("Available", PriceFormat.usdValue(available))
                Spacer()
                miniStat("Unrealized", PriceFormat.usdValue(model.unrealizedTotal, signed: true),
                         tint: model.unrealizedTotal < 0 ? .negative : (model.unrealizedTotal > 0 ? .positive : .primary), alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }

    private var available: Double {
        guard let account = model.account else { return 0 }
        return Amount.units(account.balance - min(account.balance, account.locked), decimals: 6)
    }

    // MARK: Performance stats

    private var statsGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                statTile("All-Time Volume", portfolio.loading ? "…" : usd(portfolio.totalVolume, compact: true))
                statTile("Realized P&L", portfolio.loading ? "…" : signedUSD(portfolio.realizedPnl),
                         tint: portfolio.realizedPnl < 0 ? .negative : (portfolio.realizedPnl > 0 ? .positive : .primary))
            }
            HStack(spacing: 10) {
                statTile("Win Rate", portfolio.loading ? "…" : (portfolio.winRate.map { NumberStyle.percent($0, signed: false) } ?? "—"))
                statTile("Trades", portfolio.loading ? "…" : "\(portfolio.totalTrades)")
                statTile("Fees", portfolio.loading ? "…" : usd(portfolio.totalFees, compact: true))
            }
        }
    }

    private func statTile(_ label: LocalizedStringKey, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(tint).contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground()
    }

    private func miniStat(_ label: LocalizedStringKey, _ value: String, tint: Color = .primary, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium).monospacedDigit()).foregroundStyle(tint)
        }
    }

    // MARK: Trade history

    private var historyCard: some View {
        VStack(spacing: 12) {
            Picker("History", selection: $tab) {
                ForEach(HistoryTab.allCases) { $0.title.tag($0) }
            }
            .pickerStyle(.segmented)

            if let error = portfolio.error {
                InlineError(message: error)
            } else if portfolio.loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                switch tab {
                case .fills: fillsList
                case .closed: closedList
                }
                if portfolio.truncated {
                    Text("Showing your most recent activity.").font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.top, 2)
                }
            }
        }
        .padding(14)
        .cardBackground()
    }

    @ViewBuilder private var fillsList: some View {
        if portfolio.fills.isEmpty {
            emptyRow("No fills yet")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(portfolio.fills.prefix(100)) { fill in
                    fillRow(fill)
                    if fill.id != portfolio.fills.prefix(100).last?.id { Divider() }
                }
            }
        }
    }

    private func fillRow(_ fill: PerplFill) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                (fill.side == .buy ? Text("Buy \(fill.symbol)") : Text("Sell \(fill.symbol)"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(fill.side == .buy ? Color.positive : Color.negative)
                Text(verbatim: "\(NumberStyle.number(fill.size, maximumFractionDigits: 4)) @ \(NumberStyle.number(fill.price))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(PriceFormat.usdValue(fill.notional)).font(.subheadline.monospacedDigit())
                Text(fill.time, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder private var closedList: some View {
        let closed = portfolio.records.filter(\.ended)
        if closed.isEmpty {
            emptyRow("No closed positions yet")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(closed.prefix(100)) { rec in
                    closedRow(rec)
                    if rec.id != closed.prefix(100).last?.id { Divider() }
                }
            }
        }
    }

    private func closedRow(_ rec: PerplPositionRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                (rec.side == .long ? Text("Long \(rec.symbol)") : Text("Short \(rec.symbol)"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(rec.side == .long ? Color.positive : Color.negative)
                (rec.exit.map { Text("Entry \(NumberStyle.number(rec.entry)) → \(NumberStyle.number($0))") } ?? Text("Entry \(NumberStyle.number(rec.entry))"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(PriceFormat.usdValue(rec.realizedPnl, signed: true))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(rec.realizedPnl < 0 ? Color.negative : Color.positive)
                Text(rec.time, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 9)
    }

    private func emptyRow(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func usd(_ value: Double, compact: Bool = false) -> String { PriceFormat.usdValue(value, compact: compact) }
    private func signedUSD(_ value: Double) -> String { PriceFormat.usdValue(value) }
}

/// Fetches and aggregates the authenticated Perpl history for the portfolio. Pages fills and closed positions up to
/// a cap (so a long-lived account doesn't fetch forever) and marks the result truncated when more remains.
@Observable
@MainActor
final class PerpsPortfolioModel {
    private(set) var fills: [PerplFill] = []
    private(set) var records: [PerplPositionRecord] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var truncated = false

    /// Up to 10 pages × 100 rows per stream — 1,000 fills and 1,000 closed events, plenty for the summary while
    /// bounding a first-load to a handful of round trips.
    private let maxPages = 10

    var totalVolume: Double { fills.reduce(0) { $0 + $1.notional } }
    var totalFees: Double { fills.reduce(0) { $0 + $1.fee } }
    var realizedPnl: Double { records.reduce(0) { $0 + $1.realizedPnl } }
    var totalTrades: Int { records.filter(\.ended).count }
    var winRate: Double? {
        let ended = records.filter(\.ended)
        guard !ended.isEmpty else { return nil }
        return Double(ended.filter { $0.realizedPnl > 0 }.count) / Double(ended.count) * 100
    }

    func load(env: AppEnvironment, key: PerplApiKey?, markets: [PerpMarket]) async {
        guard let key else { error = tr("Enable one-click trading in Profile to see your Perpl history."); return }
        loading = fills.isEmpty && records.isEmpty
        error = nil
        let markets = markets.isEmpty ? ((try? await env.perpl.markets()) ?? []) : markets
        guard !markets.isEmpty else { error = tr("Couldn't load markets."); loading = false; return }
        do {
            let fillResult = try await Self.page(maxPages: maxPages) { try await env.perpl.fills(key: key, markets: markets, count: 100, cursor: $0) }
            let posResult = try await Self.page(maxPages: maxPages) { try await env.perpl.positionHistory(key: key, markets: markets, count: 100, cursor: $0) }
            fills = fillResult.items
            records = posResult.items
            truncated = fillResult.more || posResult.more
        } catch {
            if fills.isEmpty && records.isEmpty { self.error = describe(error) }
        }
        loading = false
    }

    /// Pages a history endpoint until the cursor runs out or `maxPages` is hit; `more` says whether rows remain.
    private static func page<T: Sendable>(maxPages: Int, fetch: (String?) async throws -> PerplHistoryPage<T>) async rethrows -> (items: [T], more: Bool) {
        var items: [T] = []
        var cursor: String? = nil
        for _ in 0..<maxPages {
            let page = try await fetch(cursor)
            items.append(contentsOf: page.items)
            guard let next = page.next, !next.isEmpty else { return (items, false) }
            cursor = next
        }
        return (items, true)
    }
}
