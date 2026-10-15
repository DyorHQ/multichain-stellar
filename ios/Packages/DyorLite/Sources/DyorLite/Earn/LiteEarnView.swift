import StellarKit
import SwiftUI

/// Earn: supply to Blend lending pools, earn the supply APY, withdraw any time the pool has liquidity. No leverage, no
/// liquidations. A rate isn't a gain, so it is drawn in the neutral colour; a testnet rate says it is one.
struct LiteEarnView: View {
    @Environment(LiteStore.self) private var store
    @State private var selected: EarnMarket?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Earning")).font(.subheadline).foregroundStyle(.secondary)
                        Text(verbatim: earning)
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                } footer: {
                    LiteParagraph(tr("Your deposits are lent through Blend, a Stellar lending protocol. Rates move with demand. Withdrawals need the pool to have free liquidity."))
                }
                Section(tr("Markets")) {
                    ForEach(store.earnMarkets) { m in
                        Button { selected = m } label: {
                            HStack(spacing: 12) {
                                AssetBadge(code: m.code)
                                VStack(alignment: .leading) {
                                    Text(verbatim: m.code).font(.headline)
                                    Text(verbatim: Self.name(of: m, in: store)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(verbatim: percent(m.supplyApy)).font(.headline.monospacedDigit()).foregroundStyle(.primary)
                                    HStack(spacing: 4) {
                                        Text(tr("APY")).font(.caption2).foregroundStyle(.secondary)
                                        if store.isTestnet { TestnetBadge() }
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.plain)
                    }
                    if store.earnMarkets.isEmpty {
                        if store.failed.contains(.earn) {
                            LiteInlineError(message: store.lastError ?? tr("No connection. Check your network and try again."))
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                }
                if store.isTestnet {
                    Section { LiteParagraph(tr("Testnet rates come from test activity, not real markets.")).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(tr("Earn"))
            .refreshable { await store.refreshEarn() }
            .task { if store.earnMarkets.isEmpty { await store.refreshEarn() } }
            .sheet(item: $selected) { EarnMarketSheet(market: $0) }
        }
    }

    /// A market's asset as rows name it (`LiteTitles.assetName`), by its registry id: Blend's testnet pool lends its own
    /// test USDC (BUSDC), not the wallet's USDC.
    static func name(of market: EarnMarket, in store: LiteStore) -> String {
        let info = store.asset(market.asset)
        return LiteTitles.assetName(id: info?.id ?? market.asset, name: info?.name ?? market.code)
    }

    /// Whether another asset DyorHQ lists has the market's code under another id (Blend's test USDC beside the wallet's
    /// USDC on testnet): the market's sheet then says which one it is.
    static func sharesCode(_ market: EarnMarket, in store: LiteStore) -> Bool {
        let id = store.asset(market.asset)?.id ?? market.asset
        return store.config?.assets.contains { $0.code == market.code && $0.id != id } ?? false
    }

    /// What the account has supplied, per asset, or "Nothing yet".
    private var earning: String {
        store.positions.isEmpty ? tr("Nothing yet") : store.positions.map { "\(StellarAmount.format($0.supplied, maxFraction: 2)) \($0.code)" }.joined(separator: " · ")
    }
}

@MainActor
struct EarnMarketSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let market: EarnMarket
    @State private var deposit = true
    @State private var amount = ""
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?

    private var position: EarnPosition? { store.positions.first { $0.pool == market.pool && $0.asset == market.asset } }
    private var wallet: Int64 { store.account?.balances.first { $0.contract == market.asset }?.units ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Text(verbatim: percent(market.supplyApy)).monospacedDigit()
                    } label: {
                        HStack(spacing: 6) {
                            Text(tr("Supply APY"))
                            if store.isTestnet { TestnetBadge() }
                        }
                    }
                    LabeledContent(tr("Pool utilization"), value: percent(market.utilization))
                    LabeledContent(tr("In this pool"), value: "\(market.totalSupplied.formatted(.number.precision(.fractionLength(0)).locale(LiteL10n.locale))) \(market.code)")
                    if let position { LabeledContent(tr("Yours"), value: "\(StellarAmount.format(position.supplied)) \(market.code)") }
                } header: {
                    Text(verbatim: LiteEarnView.name(of: market, in: store))
                } footer: {
                    if LiteEarnView.sharesCode(market, in: store) {
                        LiteParagraph(tr("On testnet, Blend's pool uses its own test \(market.code), not the \(market.code) in your wallet. Mainnet has one \(market.code)."))
                    }
                }
                Section {
                    Picker(String(), selection: $deposit) {
                        Text(tr("Deposit")).tag(true)
                        Text(tr("Withdraw")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    AmountInput(label: deposit ? tr("Deposit") : tr("Withdraw"), text: $amount, code: market.code, maxUnits: deposit ? wallet : Int64(position?.supplied ?? "0"))
                }
                if let error { Section { LiteInlineError(message: error) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: tr("Review"), busy: busy, enabled: StellarAmount.parse(amount) != nil) {
                    Task {
                        busy = true
                        defer { busy = false }
                        do { prepared = try await store.earnPlan(deposit: deposit, market: market, amount: StellarAmount.parse(amount) ?? 0) } catch { self.error = LiteErrorText.describe(error) }
                    }
                }
                .padding()
            }
            .navigationTitle(Text(verbatim: market.code))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
            .sheet(item: $prepared) { action in
                ConfirmSheet(action: action) { _ in Task { await store.refreshEarn() } }
            }
        }
        .liteFormSheet()
    }
}
