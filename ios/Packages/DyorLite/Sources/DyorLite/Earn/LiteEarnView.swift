import StellarKit
import SwiftUI

/// Earn: Lite's replacement for Perps. Supply to Blend lending pools, earn the supply APY, withdraw any time the
/// pool has liquidity. No leverage, no liquidations.
struct LiteEarnView: View {
    @Environment(LiteStore.self) private var store
    @State private var selected: EarnMarket?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Earning").font(.subheadline).foregroundStyle(.secondary)
                        Text(store.positions.isEmpty ? "Nothing yet" : store.positions.map { "\(Amount.format($0.supplied, maxFraction: 2)) \($0.code)" }.joined(separator: " · "))
                            .font(.title2.weight(.bold))
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Your deposits are lent through Blend, a Stellar lending protocol. Rates move with demand. Withdrawals need the pool to have free liquidity.")
                }
                Section("Markets") {
                    ForEach(store.markets) { m in
                        Button { selected = m } label: {
                            HStack(spacing: 12) {
                                AssetBadge(code: m.code)
                                VStack(alignment: .leading) {
                                    Text(m.code).font(.headline)
                                    Text(m.note ?? m.poolName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(percent(m.supplyApy)).font(.headline).foregroundStyle(LiteTheme.positive)
                                    Text("APY").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if store.network.name == "testnet" {
                    Section { Text("Testnet rates come from test activity, not real markets.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Earn")
            .refreshable { await store.refreshEarn() }
            .task { if store.markets.isEmpty { await store.refreshEarn() } }
            .sheet(item: $selected) { EarnMarketSheet(market: $0) }
        }
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
                    LabeledContent("Supply APY", value: percent(market.supplyApy))
                    LabeledContent("Pool utilization", value: percent(market.utilization))
                    LabeledContent("In this pool", value: "\(market.totalSupplied.formatted(.number.precision(.fractionLength(0)))) \(market.code)")
                    if let position { LabeledContent("Yours", value: "\(Amount.format(position.supplied)) \(market.code)") }
                }
                Section {
                    Picker("", selection: $deposit) {
                        Text("Deposit").tag(true)
                        Text("Withdraw").tag(false)
                    }
                    .pickerStyle(.segmented)
                    AmountInput(label: deposit ? "Deposit" : "Withdraw", text: $amount, code: market.code, maxUnits: deposit ? wallet : Int64(position?.supplied ?? "0"))
                }
                if let error { Section { Text(error).foregroundStyle(LiteTheme.negative) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: "Review", busy: busy, enabled: Amount.parse(amount) != nil) {
                    Task {
                        busy = true
                        defer { busy = false }
                        do { prepared = try await store.earnPlan(deposit: deposit, market: market, amount: Amount.parse(amount) ?? 0) } catch { self.error = describe(error) }
                    }
                }
                .padding()
            }
            .navigationTitle(market.code)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(item: $prepared) { action in
                ConfirmSheet(action: action) { _ in Task { await store.refreshEarn() } }
            }
        }
    }
}
