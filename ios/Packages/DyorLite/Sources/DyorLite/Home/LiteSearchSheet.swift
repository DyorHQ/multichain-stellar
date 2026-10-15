import StellarKit
import SwiftUI

/// Stellar Home's search, from the host's header (design spec §3.3), in the look of Monad's token picker: the
/// account's holdings and the launches, filtered on the device by code, name, symbol or contract. A holding opens Swap
/// with it as the one to receive; a launch opens its page in Home's stack.
struct LiteSearchSheet: View {
    enum Pick: Equatable {
        case holding(asset: String)
        case launch(token: String)
    }

    /// Nil while the session is paused or still opening: nothing to list but the note about Monad.
    let store: LiteStore?
    let onPick: (Pick) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var holdings: [BalanceRow] {
        let rows = (store?.account?.balances ?? []).filter { row in row.enabled || row.units > 0 }
        return rows.filter { row in matches([row.code, row.name, row.asset, row.contract]) }
    }

    private var launches: [StellarLaunch] {
        (store?.launches ?? []).filter { launch in matches([launch.symbol, launch.name, launch.token]) }
    }

    /// Whether any of `fields` holds the query (everything matches an empty one).
    private func matches(_ fields: [String]) -> Bool {
        let query = trimmed
        return query.isEmpty || fields.contains { field in field.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let holdings = self.holdings
        let launches = self.launches
        NavigationStack {
            List {
                if !holdings.isEmpty {
                    Section(tr("My Holdings")) {
                        ForEach(holdings) { row in
                            pickRow(code: row.code, name: LiteTitles.assetName(id: row.asset, name: row.name),
                                    trailing: StellarAmount.format(row.units, maxFraction: 4)) { .holding(asset: row.asset) }
                        }
                    }
                }
                if !launches.isEmpty {
                    Section(tr("Launches")) {
                        ForEach(launches) { launch in
                            pickRow(code: launch.symbol, name: launch.name, trailing: nil) { .launch(token: launch.token) }
                        }
                    }
                }
                if holdings.isEmpty && launches.isEmpty {
                    Section {
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            if !trimmed.isEmpty {
                                LiteParagraph(tr("No Stellar tokens match “\(trimmed)”."))
                            }
                            LiteParagraph(tr("Monad tokens show when you switch to Monad."))
                                .font(.footnote)
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: tr("Symbol, name or address"))
            .navigationTitle(tr("Choose a Token"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Cancel")) { dismiss() } } }
        }
    }

    private func pickRow(code: String, name: String, trailing: String?, pick: @escaping () -> Pick) -> some View {
        Button {
            LiteHaptics.selection()
            onPick(pick())
            dismiss()
        } label: {
            HStack(spacing: 12) {
                AssetBadge(code: code, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: code).font(.headline)
                    Text(verbatim: name).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let trailing { Text(verbatim: trailing).monospacedDigit().foregroundStyle(.secondary) }
            }
        }
        .foregroundStyle(.primary)
    }
}
