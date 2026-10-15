import Charts
import PhotosUI
import StellarKit
import SwiftUI

/// The Stellar launchpad: same economics as Monad's (1B supply, 1% fee, 10× to graduation), curve-only until it
/// graduates into Soroswap with its liquidity locked.
struct LiteLaunchView: View {
    @Environment(LiteStore.self) private var store
    @State private var sort = "new"
    @State private var creating = false

    var body: some View {
        NavigationStack {
            // Laid out as Moments is: the switch and the card on the screen's 16 pt margins, the card fully rounded.
            ScrollView {
                Picker(tr("Sort"), selection: $sort) {
                    Text(tr("New")).tag("new")
                    Text(tr("Hot")).tag("hot")
                    Text(tr("Graduated")).tag("graduated")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                Group {
                    if store.launches.isEmpty {
                        if store.failed.contains(.launches) {
                            LiteInlineError(message: store.lastError ?? tr("No connection. Check your network and try again."))
                        } else if store.loaded.contains(.launches) {
                            ContentUnavailableView(tr("No launches yet"), systemImage: "flame", description: Text(tr("Be the first: tap + to launch a coin.")))
                        } else {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                    } else {
                        launchList
                    }
                }
                .padding(16)
            }
            .background(Color.liteCanvas)
            .navigationTitle(tr("Launch"))
            .navigationDestination(for: String.self) { LaunchDetailView(token: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel(tr("Launch a coin"))
                }
            }
            .task(id: sort) { await store.refreshLaunches(sort: sort) }
            .refreshable { await store.refreshLaunches(sort: sort) }
            .sheet(isPresented: $creating) { CreateLaunchSheet() }
        }
    }

    private var launchList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.launches.enumerated()), id: \.element.id) { index, launch in
                NavigationLink(value: launch.token) {
                    HStack(spacing: 8) {
                        LaunchRow(launch: launch)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < store.launches.count - 1 { Divider().padding(.leading, 56) }
            }
        }
        .padding(.horizontal, 16)
        .liteCardBackground()
    }
}

struct LaunchRow: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.liteStyle) private var style
    let launch: StellarLaunch

    var body: some View {
        HStack(spacing: 12) {
            AssetBadge(code: launch.symbol, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: launch.symbol).font(.headline)
                    if launch.graduated { Text(tr("On Soroswap")).font(.caption2.weight(.bold)).foregroundStyle(style.accent) }
                }
                Text(verbatim: launch.name).font(.caption).foregroundStyle(.secondary)
                ProgressView(value: launch.progress).tint(style.accent)
                    .accessibilityLabel(tr("\(Int(launch.progress * 100))% to graduation"))
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(tr("\(launch.trades) trades")).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: "\(StellarAmount.format(launch.volume, maxFraction: 0)) \(store.asset(launch.quote)?.code ?? "")").font(.caption.monospacedDigit())
            }
        }
    }
}

@MainActor
struct LaunchDetailView: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.liteStyle) private var style
    let token: String
    @State private var detail: StellarLaunchDetail?
    @State private var buying = true
    @State private var amount = ""
    @State private var preview: StellarLaunchQuote?
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
            } else if let error {
                LiteInlineError(message: error).padding(40)
            } else {
                ProgressView().padding(40)
            }
        }
        .background(Color.liteCanvas)
        .navigationTitle(Text(verbatim: detail?.launch.symbol ?? ""))
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in Task { await load() } } }
        .sheet(isPresented: $swapping) {
            SwapSheet(initialSell: buying ? (detail.map { quoteID($0) } ?? "XLM") : token, initialBuy: buying ? token : (detail.map { quoteID($0) } ?? "XLM"))
        }
    }

    private func quoteID(_ d: StellarLaunchDetail) -> String { store.asset(d.launch.quote)?.id ?? d.launch.quote }
    private func quoteCode(_ d: StellarLaunchDetail) -> String { store.asset(d.launch.quote)?.code ?? "" }

    private func load() async {
        do {
            detail = try await store.launchDetail(token)
            error = nil
        } catch { self.error = LiteErrorText.describe(error) }
    }

    private func header(_ d: StellarLaunchDetail) -> some View {
        LiteCard {
            HStack(spacing: 12) {
                AssetBadge(code: d.launch.symbol, size: 52)
                VStack(alignment: .leading) {
                    Text(verbatim: d.launch.name).font(.title2.bold())
                    Text(tr("by \(shortAddress(d.launch.creator))")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: d.launch.progress) {
                Text(d.launch.graduated ? tr("Graduated to Soroswap") : tr("\(Int(d.launch.progress * 100))% to graduation"))
                    .font(.caption)
            }
            .tint(style.accent)
            if let price = d.launch.lastPrice, let p = Double(price) {
                Text(tr("Price \(p.formatted(.number.precision(.significantDigits(4)).locale(LiteL10n.locale))) \(quoteCode(d))"))
                    .font(.subheadline.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private func chart(_ d: StellarLaunchDetail) -> some View {
        let points = d.candles.reversed().compactMap { c -> PricePoint? in
            guard let t = c.t.liteDate, let v = Double(c.c) else { return nil }
            return PricePoint(time: t, price: v)
        }
        if points.count >= 2 {
            LiteCard {
                Chart(points) { p in
                    AreaMark(x: .value(tr("Time"), p.time), y: .value(tr("Price"), p.price))
                        .foregroundStyle(LinearGradient(colors: [style.accent.opacity(0.12), style.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value(tr("Time"), p.time), y: .value(tr("Price"), p.price)).foregroundStyle(style.accent)
                }
                .frame(height: 160)
                .accessibilityLabel(tr("Price chart"))
            }
        }
    }

    private func trade(_ d: StellarLaunchDetail) -> some View {
        LiteCard {
            Picker(String(), selection: $buying) {
                Text(tr("Buy")).tag(true)
                Text(tr("Sell")).tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: buying) { _, _ in preview = nil }
            AmountInput(label: buying ? tr("Pay") : tr("Sell"), text: $amount, code: buying ? quoteCode(d) : d.launch.symbol,
                        maxUnits: buying ? store.account?.balance(quoteID(d)) : store.account?.balance(token))
                .onChange(of: amount) { _, _ in preview = nil }
            if let q = preview {
                if buying {
                    Text(tr("You get about \(StellarAmount.format(q.out, maxFraction: 4)) \(d.launch.symbol)")).font(.subheadline)
                    if let s = q.quote.snipeFee, s != "0" {
                        LiteInlineError(message: tr("Opening-seconds anti-snipe fee applies: \(StellarAmount.format(s)) \(quoteCode(d))"))
                    }
                } else {
                    Text(tr("You get about \(StellarAmount.format(q.out, maxFraction: 4)) \(quoteCode(d))")).font(.subheadline)
                }
            }
            if let error { LiteInlineError(message: error) }
            LitePrimaryButton(title: preview == nil ? tr("Get price") : tr("Review"), busy: busy, enabled: StellarAmount.parse(amount) != nil) {
                Task { await tradeTapped(d) }
            }
        }
    }

    private func tradeTapped(_ d: StellarLaunchDetail) async {
        guard let units = StellarAmount.parse(amount) else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            guard let q = preview else {
                preview = try await store.launchQuote(token: token, buy: buying, amount: units)
                return
            }
            // The curve's fixed 1% slippage (R11).
            prepared = try await store.launchTradePlan(token: token, buy: buying, amount: units, minOut: q.minOut)
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }

    private func completed(_ d: StellarLaunchDetail) -> some View {
        LiteCard {
            LiteParagraph(tr("This launch hit its target and is moving to Soroswap.")).font(.subheadline)
            LitePrimaryButton(title: tr("Graduate now (free)"), busy: busy) {
                Task {
                    do { prepared = try await store.graduatePlan(token: token) } catch { self.error = LiteErrorText.describe(error) }
                }
            }
        }
    }

    private func graduated(_ d: StellarLaunchDetail) -> some View {
        LiteCard {
            LiteParagraph(tr("Trading on Soroswap. Liquidity is locked forever.")).font(.subheadline)
            HStack {
                Button(tr("Buy")) { buying = true; swapping = true }.buttonStyle(.borderedProminent)
                Button(tr("Sell")) { buying = false; swapping = true }.buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
            if d.launch.creator == store.address, let fees = d.curve?.creatorFees, fees != "0" {
                Button(tr("Claim \(StellarAmount.format(fees)) \(quoteCode(d)) creator fees")) {
                    Task { prepared = try? await store.claimPlan(tokens: [token]).first }
                }
            }
        }
    }

    private func trades(_ d: StellarLaunchDetail) -> some View {
        LiteCard {
            Text(tr("Trades")).font(.headline)
            ForEach(Array(d.trades.prefix(20).enumerated()), id: \.offset) { _, t in
                HStack {
                    Text(t.side == "buy" ? tr("Buy") : tr("Sell"))
                        .foregroundStyle(t.side == "buy" ? style.positive : style.negative)
                        .font(.caption.weight(.bold))
                    Text(verbatim: shortAddress(t.trader)).font(.caption.monospaced())
                    Spacer()
                    Text(verbatim: "\(StellarAmount.format(t.quoteAmount)) \(quoteCode(d))").font(.caption.monospacedDigit())
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
                    TextField(tr("Name"), text: $name)
                    TextField(tr("Ticker"), text: $symbol)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label(imageData == nil ? tr("Add an image") : tr("Image added"), systemImage: "photo")
                    }
                }
                Section {
                    Picker(tr("Priced in"), selection: $quote) {
                        Text(verbatim: "XLM").tag("XLM")
                        Text(verbatim: "USDC").tag("USDC")
                    }
                    AmountInput(label: tr("Your first buy (optional, no anti-snipe fee)"), text: $initialBuy, code: quote, maxUnits: store.account?.balance(quote))
                    VStack(alignment: .leading) {
                        Text(tr("Creator fee on every trade: \(creatorFee.formatted(.number.precision(.fractionLength(1)).locale(LiteL10n.locale)))%"))
                        Slider(value: $creatorFee, in: 0...10, step: 0.5)
                    }
                } footer: {
                    LiteParagraph(tr("1,000,000,000 coins. Everyone buys on the same curve; at its target it moves to Soroswap with its liquidity locked forever. You also earn half of the 1% trading fee."))
                }
                if let error { Section { LiteInlineError(message: error) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: tr("Review launch"), busy: busy, enabled: !name.isEmpty && !symbol.isEmpty) { Task { await review() } }.padding()
            }
            .navigationTitle(tr("Launch a coin"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
            .onChange(of: photo) { _, item in
                Task { imageData = try? await item?.loadTransferable(type: Data.self) }
            }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in Task { await store.refreshLaunches(sort: "new") }; dismiss() } }
        }
        .liteFormSheet()
    }

    private func review() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let form = StellarLaunchForm(name: name, symbol: symbol.uppercased(), quote: quote, creatorFeeBps: Int(creatorFee * 100),
                                         developerBuy: StellarAmount.parse(initialBuy) ?? 0)
            prepared = try await store.launchCreatePlan(form, image: imageData.map(jpeg))
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }
}
