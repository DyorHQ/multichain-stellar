// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift SelectPerpetualSheet (42cd8c7 sha256:e0df064d322f)
// Earn's market picker (docs/DESIGN-stellar-parity.md §8.6.3). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// The market picker of Stellar's Earn, as Perps' Select Perpetual sheet: a search capsule and every Blend market, each
/// with its asset's logo, its code and pool, its supply APY and how much of the pool is lent out; the market on screen is
/// highlighted. Every market is listed, none hidden. Picking one switches Earn to it in place.
struct StellarSelectMarketSheet: View {
    let markets: [EarnMarket]
    let currentId: String
    /// The registry's entry for a market's asset: its classic form picks the logo, its name is searched.
    let asset: (EarnMarket) -> AssetInfo?
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// The markets whose code, pool or asset name contains the search.
    static func filtered(_ markets: [EarnMarket], query: String, asset: (EarnMarket) -> AssetInfo?) -> [EarnMarket] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return markets }
        return markets.filter { market in
            [market.code, market.poolName, asset(market)?.name ?? ""].contains { $0.lowercased().contains(q) }
        }
    }

    private var filtered: [EarnMarket] { Self.filtered(markets, query: query, asset: asset) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: Text("Select Market", tableName: "StellarEarn", comment: "The title of Stellar Earn's market picker: choose which Blend market the screen shows (title case)")) { dismiss() }
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
                        .accessibilityAddTraits(market.id == currentId ? .isSelected : [])
                        if market.id != filtered.last?.id { Divider().padding(.leading, 64) }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 6)
                if filtered.isEmpty, !markets.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 24)
                }
            }
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
    }

    private func marketRow(_ market: EarnMarket) -> some View {
        let selected = market.id == currentId
        let apy = NumberStyle.percent(market.supplyApyPercent, signed: false)
        let utilization = NumberStyle.percent(market.utilizationPercent, signed: false)
        return HStack(spacing: 12) {
            StellarTokenLogo(symbol: market.code, classic: asset(market)?.classic, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: market.code).font(.body.weight(.bold))
                Text(verbatim: market.poolName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: apy)
                    .font(.body.weight(.semibold)).monospacedDigit()
                StellarEarnWords.utilizationValue(utilization)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(selected ? Color(.tertiarySystemFill) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(market.code), \(market.poolName), supply APY \(apy), utilization \(utilization)", tableName: "StellarEarn", comment: "VoiceOver: a market in Stellar Earn's market picker. The values are the asset's code (XLM), the Blend pool's name, the supply rate (4.21%) and how much of the pool is lent out (62.30%)"))
    }
}
#endif
