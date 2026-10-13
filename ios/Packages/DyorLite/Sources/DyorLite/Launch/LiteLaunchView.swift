import Charts
import PhotosUI
import StellarKit
import SwiftUI

/// The Stellar launchpad: same economics as Pro's (1B supply, 1% fee, 10× to graduation), curve-only until it
/// graduates into Soroswap with its liquidity locked.
struct LiteLaunchView: View {
    @Environment(LiteStore.self) private var store
    @State private var sort = "new"
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Picker("Sort", selection: $sort) {
                    Text("New").tag("new")
                    Text("Hot").tag("hot")
                    Text("Graduated").tag("graduated")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                if store.launches.isEmpty {
                    ContentUnavailableView("No launches yet", systemImage: "flame", description: Text("Be the first: tap + to launch a coin."))
                }
                ForEach(store.launches) { launch in
                    NavigationLink(value: launch.token) { LaunchRow(launch: launch) }
                }
            }
            .navigationTitle("Launch")
            .navigationDestination(for: String.self) { LaunchDetailView(token: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("Launch a coin")
                }
            }
            .task(id: sort) { await store.refreshLaunches(sort: sort) }
            .refreshable { await store.refreshLaunches(sort: sort) }
            .sheet(isPresented: $creating) { CreateLaunchSheet() }
        }
    }
}

struct LaunchRow: View {
    @Environment(LiteStore.self) private var store
    let launch: Launch

    var body: some View {
        HStack(spacing: 12) {
            AssetBadge(code: launch.symbol, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(launch.symbol).font(.headline)
                    if launch.graduated { Text("On Soroswap").font(.caption2.weight(.bold)).foregroundStyle(LiteTheme.accent) }
                }
                Text(launch.name).font(.caption).foregroundStyle(.secondary)
                ProgressView(value: launch.progress).tint(LiteTheme.accent)
                    .accessibilityLabel("\(Int(launch.progress * 100)) percent to graduation")
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("\(launch.trades) trades").font(.caption).foregroundStyle(.secondary)
                Text("\(Amount.format(launch.volume, maxFraction: 0)) \(store.asset(launch.quote)?.code ?? "")").font(.caption.monospacedDigit())
            }
        }
    }
}

@MainActor
struct LaunchDetailView: View {
    @Environment(LiteStore.self) private var store
    let token: String
    @State private var detail: LaunchDetail?
    @State private var buying = true
    @State private var amount = ""
    @State private var preview: TradeQuote?
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?
    @State private var swapping = false

    var body: some View {
        ScrollView {
            if let d = detail {
                VStack(alignment: .leading, spacing: 16) {
                    header(d)
                    chart(d)
                    if d.launch.graduated { graduated(d) } else if d.curve?.completed == true { completed(d) } else { trade(d) }
                    trades(d)
                }
                .padding(16)
            } else {
                ProgressView().padding(40)
            }
        }
        .background(LiteTheme.canvas)
        .navigationTitle(detail?.launch.symbol ?? "")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in Task { await load() } } }
        .sheet(isPresented: $swapping) {
            SwapSheet(initialSell: buying ? (detail.map { quoteID($0) } ?? "XLM") : token, initialBuy: buying ? token : (detail.map { quoteID($0) } ?? "XLM"))
        }
    }

    private func quoteID(_ d: LaunchDetail) -> String { store.asset(d.launch.quote)?.id ?? d.launch.quote }
    private func quoteCode(_ d: LaunchDetail) -> String { store.asset(d.launch.quote)?.code ?? "" }

    private func load() async {
        do { detail = try await store.launchDetail(token) } catch { self.error = describe(error) }
    }

    private func header(_ d: LaunchDetail) -> some View {
        LiteCard {
            HStack(spacing: 12) {
                AssetBadge(code: d.launch.symbol, size: 52)
                VStack(alignment: .leading) {
                    Text(d.launch.name).font(.title2.bold())
                    Text("by \(shortAddress(d.launch.creator))").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: d.launch.progress) {
                Text(d.launch.graduated ? "Graduated to Soroswap" : "\(Int(d.launch.progress * 100))% to graduation")
                    .font(.caption)
            }
            .tint(LiteTheme.accent)
            if let price = d.launch.lastPrice, let p = Double(price) {
                Text("Price \(p.formatted(.number.precision(.significantDigits(4)))) \(quoteCode(d))").font(.subheadline.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private func chart(_ d: LaunchDetail) -> some View {
        let points = d.candles.reversed().compactMap { c -> PricePoint? in
            guard let t = ISO8601DateFormatter.liteUI.date(from: c.t) ?? ISO8601DateFormatter().date(from: c.t), let v = Double(c.c) else { return nil }
            return PricePoint(time: t, price: v)
        }
        if points.count >= 2 {
            LiteCard {
                Chart(points) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Price", p.price)).foregroundStyle(LiteTheme.accent)
                }
                .frame(height: 160)
                .accessibilityLabel("Price chart")
            }
        }
    }

    private func trade(_ d: LaunchDetail) -> some View {
        LiteCard {
            Picker("", selection: $buying) {
                Text("Buy").tag(true)
                Text("Sell").tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: buying) { _, _ in preview = nil }
            AmountInput(label: buying ? "Pay" : "Sell", text: $amount, code: buying ? quoteCode(d) : d.launch.symbol,
                        maxUnits: buying ? store.account?.balance(quoteID(d)) : store.account?.balance(token))
                .onChange(of: amount) { _, _ in preview = nil }
            if let q = preview {
                if buying {
                    Text("You get about \(Amount.format(q.tokensOut ?? "0")) \(d.launch.symbol)").font(.subheadline)
                    if let s = q.snipeFee, s != "0" { Text("Opening-seconds anti-snipe fee applies: \(Amount.format(s)) \(quoteCode(d))").font(.caption).foregroundStyle(.orange) }
                } else {
                    Text("You get about \(Amount.format(q.quoteOut ?? "0")) \(quoteCode(d))").font(.subheadline)
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(LiteTheme.negative) }
            LitePrimaryButton(title: preview == nil ? "Get price" : "Review", busy: busy, enabled: Amount.parse(amount) != nil) {
                Task { await tradeTapped(d) }
            }
        }
    }

    private func tradeTapped(_ d: LaunchDetail) async {
        guard let units = Amount.parse(amount) else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            guard let q = preview else {
                preview = try await store.quoteTrade(token: token, buy: buying, amount: units)
                return
            }
            // 2% slippage on the curve quote.
            let expected = Int64(buying ? (q.tokensOut ?? "0") : (q.quoteOut ?? "0")) ?? 0
            let minOut = expected * 98 / 100
            var req = LiteAPI.LaunchRequest(action: buying ? "buy" : "sell", token: token)
            req.amount = String(units)
            req.minOut = String(minOut)
            prepared = try await store.launchPlan(req, spend: (asset: buying ? d.launch.quote : token, amount: units))
        } catch {
            self.error = describe(error)
        }
    }

    private func completed(_ d: LaunchDetail) -> some View {
        LiteCard {
            Text("This launch hit its target and is moving to Soroswap.").font(.subheadline)
            LitePrimaryButton(title: "Graduate now (free)", busy: busy) {
                Task {
                    do { prepared = try await store.launchPlan(LiteAPI.LaunchRequest(action: "graduate", token: token), spend: nil) } catch { self.error = describe(error) }
                }
            }
        }
    }

    private func graduated(_ d: LaunchDetail) -> some View {
        LiteCard {
            Text("Trading on Soroswap. Liquidity is locked forever.").font(.subheadline)
            HStack {
                Button("Buy") { buying = true; swapping = true }.buttonStyle(.borderedProminent)
                Button("Sell") { buying = false; swapping = true }.buttonStyle(.bordered)
            }
            if d.launch.creator == store.keys.address, let fees = d.curve?.creatorFees, fees != "0" {
                Button("Claim \(Amount.format(fees)) \(quoteCode(d)) creator fees") {
                    Task { prepared = try? await store.launchPlan(LiteAPI.LaunchRequest(action: "claim", token: token), spend: nil) }
                }
            }
        }
    }

    private func trades(_ d: LaunchDetail) -> some View {
        LiteCard {
            Text("Trades").font(.headline)
            ForEach(Array(d.trades.prefix(20).enumerated()), id: \.offset) { _, t in
                HStack {
                    Text(t.side == "buy" ? "Buy" : "Sell").foregroundStyle(t.side == "buy" ? LiteTheme.positive : LiteTheme.negative).font(.caption.weight(.bold))
                    Text(shortAddress(t.trader)).font(.caption.monospaced())
                    Spacer()
                    Text("\(Amount.format(t.quoteAmount)) \(quoteCode(d))").font(.caption.monospacedDigit())
                }
            }
        }
    }
}

struct PricePoint: Identifiable {
    let time: Date
    let price: Double
    var id: Date { time }
}

struct CreateLaunchSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = ""
    @State private var quote = "XLM"
    @State private var initialBuy = ""
    @State private var creatorFee = 0.0
    @State private var photo: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Ticker", text: $symbol)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label(imageData == nil ? "Add an image" : "Image added", systemImage: "photo")
                    }
                }
                Section {
                    Picker("Priced in", selection: $quote) {
                        Text("XLM").tag("XLM")
                        Text("USDC").tag("USDC")
                    }
                    AmountInput(label: "Your first buy (optional, no anti-snipe fee)", text: $initialBuy, code: quote, maxUnits: store.account?.balance(quote))
                    VStack(alignment: .leading) {
                        Text("Creator fee on every trade: \(creatorFee, format: .number.precision(.fractionLength(1)))%")
                        Slider(value: $creatorFee, in: 0...10, step: 0.5)
                    }
                } footer: {
                    Text("1,000,000,000 coins. Everyone buys on the same curve; at its target it moves to Soroswap with its liquidity locked forever. You also earn half of the 1% trading fee.")
                }
                if let error { Section { Text(error).foregroundStyle(LiteTheme.negative) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: "Review launch", busy: busy, enabled: !name.isEmpty && !symbol.isEmpty) { Task { await review() } }.padding()
            }
            .navigationTitle("Launch a coin")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: photo) { _, item in
                Task { imageData = try? await item?.loadTransferable(type: Data.self) }
            }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in Task { await store.refreshLaunches(sort: "new") }; dismiss() } }
        }
    }

    private func review() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            var uri = ""
            if let imageData { uri = try await store.uploadImage(jpeg(imageData), contentType: "image/jpeg") }
            let buy = Amount.parse(initialBuy) ?? 0
            var req = LiteAPI.LaunchRequest(action: "create", quote: quote, name: name, symbol: symbol.uppercased(), uri: uri, creatorFeeBps: Int(creatorFee * 100))
            req.amount = String(buy)
            req.minOut = "0"
            prepared = try await store.launchPlan(req, spend: buy > 0 ? (asset: quote, amount: buy) : nil)
        } catch {
            self.error = describe(error)
        }
    }
}
