import StellarKit
import SwiftUI

@MainActor
struct LiteHomeView: View {
    @Environment(LiteStore.self) private var store
    let onSwitchToPro: () -> Void

    enum SheetKind: String, Identifiable {
        case cash, send, receive, swap, bridge, settings
        var id: String { rawValue }
    }

    @State private var sheet: SheetKind?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ModePill(isLite: true, action: onSwitchToPro)
                    balanceCard
                    actions
                    assets
                    activity
                }
                .padding(16)
            }
            .background(LiteTheme.canvas)
            .refreshable { await store.refreshAll() }
            .navigationTitle("Lite")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Lite settings")
                }
            }
            .sheet(item: $sheet) { kind in
                switch kind {
                case .cash: CashSheet()
                case .send: SendSheet()
                case .receive: ReceiveSheet()
                case .swap: SwapSheet()
                case .bridge: BridgeSheet()
                case .settings: LiteSettingsView(onSwitchToPro: onSwitchToPro)
                }
            }
        }
    }

    private var balanceCard: some View {
        LiteCard {
            HStack {
                Text("Balance").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if store.network.name == "testnet" { TestnetBadge() }
            }
            Text(usd(store.totalUSD))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            if let p = store.prices { Text(p.reference).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            action("Add cash", "plus.circle.fill", .cash)
            action("Send", "arrow.up.circle.fill", .send)
            action("Receive", "qrcode", .receive)
            action("Swap", "arrow.left.arrow.right.circle.fill", .swap)
            action("Monad", "arrow.triangle.swap", .bridge)
        }
    }

    private func action(_ title: String, _ icon: String, _ kind: SheetKind) -> some View {
        Button { sheet = kind } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(LiteTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(LiteTheme.accent)
    }

    private var assets: some View {
        LiteCard {
            Text("Assets").font(.headline)
            ForEach(store.account?.balances.filter { $0.enabled || $0.units > 0 } ?? []) { row in
                HStack(spacing: 12) {
                    AssetBadge(code: row.code)
                    VStack(alignment: .leading) {
                        Text(row.code).font(.body.weight(.semibold))
                        Text(row.note ?? row.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(Amount.format(row.units, maxFraction: 4)).font(.body.monospacedDigit())
                        if let px = store.prices?.usd[row.asset] ?? store.prices?.usd[row.contract], px > 0 {
                            Text(usd(Double(row.units) / 1e7 * px)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(store.positions) { p in
                HStack(spacing: 12) {
                    AssetBadge(code: p.code)
                    VStack(alignment: .leading) {
                        Text("\(p.code) earning").font(.body.weight(.semibold))
                        Text("Blend").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Amount.format(p.supplied, maxFraction: 4)).font(.body.monospacedDigit())
                }
            }
        }
    }

    private var activity: some View {
        LiteCard {
            Text("Activity").font(.headline)
            if store.activity.isEmpty {
                Text("Nothing yet. Add cash or swap to get started.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(store.activity.prefix(12)) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.summary).font(.subheadline).lineLimit(2)
                        Text(item.at.prefix(16).replacingOccurrences(of: "T", with: " ")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(statusWord(item.status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.status == "failed" ? LiteTheme.negative : .secondary)
                }
            }
        }
    }

    private func statusWord(_ s: String) -> String {
        switch s {
        case "success", "completed": return "Done"
        case "failed": return "Failed"
        default: return "Pending"
        }
    }
}

// ------------------------------------------------------------------------------------------------ swap

@MainActor
struct SwapSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var initialSell = "XLM"
    var initialBuy = "USDC"
    @State private var sell = "XLM"
    @State private var buy = "USDC"
    @State private var amount = ""
    @State private var quote: SwapQuote?
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Pay with", selection: $sell) { ForEach(choices, id: \.self) { Text(code($0)).tag($0) } }
                    AmountInput(label: "Amount", text: $amount, code: code(sell), maxUnits: store.account?.balance(sell))
                    Button {
                        let s = sell
                        sell = buy
                        buy = s
                    } label: { Label("Flip", systemImage: "arrow.up.arrow.down") }
                    Picker("Receive", selection: $buy) { ForEach(choices, id: \.self) { Text(code($0)).tag($0) } }
                }
                if let quote {
                    Section("Best price") {
                        LabeledContent("You get about", value: "\(Amount.format(quote.best.amountOut)) \(code(buy))")
                        LabeledContent("At least", value: "\(Amount.format(quote.best.minOut ?? quote.best.amountOut)) \(code(buy))")
                        LabeledContent("Route", value: quote.best.venue.capitalized)
                        ForEach(quote.alternatives, id: \.venue) { alt in
                            LabeledContent(alt.venue.capitalized, value: Amount.format(alt.amountOut)).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(LiteTheme.negative) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: quote == nil ? "Get price" : "Review swap", busy: busy, enabled: Amount.parse(amount) != nil && sell != buy) {
                    Task { await next() }
                }
                .padding()
            }
            .navigationTitle("Swap")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: amount) { _, _ in quote = nil }
            .onChange(of: sell) { _, _ in quote = nil }
            .onChange(of: buy) { _, _ in quote = nil }
            .onAppear {
                sell = initialSell
                buy = initialBuy
            }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in dismiss() } }
        }
    }

    private var choices: [String] {
        var ids = ["XLM", "USDC"]
        if store.network.name == "testnet" { ids.append("BUSDC") }
        ids += store.account?.balances.filter { $0.classic == nil }.map(\.asset) ?? []
        for id in [initialSell, initialBuy] where !ids.contains(id) { ids.append(id) }
        return ids
    }

    private func code(_ id: String) -> String {
        store.account?.balances.first { $0.asset == id }?.code ?? store.asset(id)?.code ?? store.launches.first { $0.token == id }?.symbol ?? shortAddress(id)
    }

    private func next() async {
        guard let units = Amount.parse(amount) else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            if let quote {
                prepared = try await store.swapPlan(quote)
            } else {
                quote = try await store.quoteSwap(sell: sell, buy: buy, amount: units, slippageBps: 100)
            }
        } catch {
            self.error = describe(error)
        }
    }
}

// ------------------------------------------------------------------------------------------------ send & receive

struct SendSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var asset = "XLM"
    @State private var to = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Asset", selection: $asset) {
                    ForEach(store.account?.balances.filter { $0.enabled } ?? []) { Text($0.code).tag($0.asset) }
                }
                TextField("To (G… address)", text: $to).font(.body.monospaced()).autocorrectionDisabled()
                AmountInput(label: "Amount", text: $amount, code: store.account?.balances.first { $0.asset == asset }?.code ?? "", maxUnits: store.account?.balance(asset))
                TextField("Memo (exchanges and anchors may require one)", text: $memo)
                if let error { Text(error).foregroundStyle(LiteTheme.negative) }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: "Review", busy: busy, enabled: StrKey.isValid(.accountID, to) && Amount.parse(amount) != nil) {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            prepared = try await store.sendPlan(asset: asset, to: to, amount: Amount.parse(amount) ?? 0, memo: memo.isEmpty ? nil : memo, memoType: memo.allSatisfy(\.isNumber) && !memo.isEmpty ? "id" : "text")
                        } catch { self.error = describe(error) }
                    }
                }
                .padding()
            }
            .navigationTitle("Send")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in dismiss() } }
        }
    }
}

struct ReceiveSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                QRCodeView(text: store.keys.address).frame(width: 220, height: 220)
                Text(store.keys.address).font(.footnote.monospaced()).multilineTextAlignment(.center).textSelection(.enabled)
                Button(copied ? "Copied" : "Copy address") {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = store.keys.address
                    #endif
                    copied = true
                }
                .buttonStyle(.bordered)
                Text("Send only Stellar assets to this address. To move USDC from Monad, use Monad on the Home screen.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if store.network.name == "testnet" {
                    Button("Get 10,000 test XLM") { Task { try? await store.faucet() } }.font(.footnote)
                }
            }
            .padding(24)
            .navigationTitle("Receive")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
