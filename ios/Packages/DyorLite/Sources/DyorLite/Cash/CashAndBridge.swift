import StellarKit
import SwiftUI

/// Add cash / cash out through SEP-24 anchors. The anchor's own page runs in an in-app browser; the store signs in to
/// the anchor with the Stellar key (SEP-10, inside DyorLite) and follows the transfer. For a withdrawal the anchor gives
/// an address and memo, and the phone sends the payment, its network fee paid in XLM like any other.
@MainActor
struct CashSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var anchors: [AnchorInfo] = []
    @State private var loaded = false
    @State private var deposit: Bool
    @State private var asset = "USDC"
    @State private var web: WebPage?
    @State private var tracking: LiteCashFlow?
    @State private var status: AnchorClient.AnchorTransaction?
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?

    /// `deposit`: Add cash at first, else Cash out.
    init(deposit: Bool = true) {
        _deposit = State(initialValue: deposit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(), selection: $deposit) {
                        Text(tr("Add cash")).tag(true)
                        Text(tr("Cash out")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    Picker(tr("Asset"), selection: $asset) {
                        Text(verbatim: "USDC").tag("USDC")
                        Text(verbatim: "XLM").tag("native")
                    }
                }
                Section(tr("Providers")) {
                    ForEach(anchors) { a in
                        Button { Task { await start(a) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: a.name).font(.headline).foregroundStyle(.primary)
                                    Text(verbatim: a.domain).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        // A row that opens the provider, not a tinted button.
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                    if anchors.isEmpty {
                        if loaded { Text(tr("No provider for your country yet.")).foregroundStyle(.secondary) } else { ProgressView() }
                    }
                }
                if let status {
                    Section(tr("Status")) {
                        LabeledContent(tr("Transfer"), value: status.status.replacingOccurrences(of: "_", with: " "))
                        if let m = status.message { Text(verbatim: m).font(.footnote) }
                        if !deposit, status.status == "pending_user_transfer_start", status.withdraw_anchor_account != nil, let amount = status.amount_in {
                            LitePrimaryButton(title: tr("Send \(amount) \(asset == "native" ? "XLM" : asset) to the provider"), busy: busy) {
                                Task { await payAnchor(status) }
                            }
                        }
                        Button(tr("Refresh")) { Task { await refresh() } }
                    }
                }
                if let error { Section { LiteInlineError(message: error) } }
                if store.isTestnet {
                    Section { LiteParagraph(tr("Testnet uses the Stellar test anchor: no real money moves.")).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(deposit ? tr("Add cash") : tr("Cash out"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
            .task {
                do { anchors = try await store.anchors() } catch { self.error = LiteErrorText.describe(error) }
                loaded = true
            }
            .sheet(item: $web) { page in
                SafariView(url: page.url).ignoresSafeArea().onDisappear { Task { await refresh() } }
            }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in Task { await refresh() } } }
        }
        .liteFormSheet()
    }

    private func start(_ a: AnchorInfo) async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let flow = try await store.startCash(anchor: a, deposit: deposit, asset: asset == "native" ? "XLM" : asset)
            tracking = flow
            web = WebPage(url: flow.url)
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }

    private func refresh() async {
        guard let flow = tracking else { return }
        do {
            status = try await store.cashStatus(flow)
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }

    private func payAnchor(_ transaction: AnchorClient.AnchorTransaction) async {
        guard let flow = tracking else { return }
        busy = true
        defer { busy = false }
        do {
            prepared = try await store.cashOutPlan(flow, transaction: transaction)
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }
}

struct WebPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// USDC between Monad and Stellar. Testnet: Circle CCTP. Monad → Stellar is signed by the account's Monad wallet (the
/// host provides it); Stellar → Monad burns here and is claimed on Monad by the Monad wallet once Circle attests.
struct BridgeSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var toStellar: Bool
    @State private var amount = ""
    @State private var monadAddress = ""
    @State private var transfer: BridgeTransfer?
    @State private var status: BridgeStatus?
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?

    /// `toStellar`: Monad → Stellar at first, else Stellar → Monad.
    init(toStellar: Bool = true) {
        _toStellar = State(initialValue: toStellar)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(), selection: $toStellar) {
                        // Network names, never translated.
                        Text(verbatim: "Monad → Stellar").tag(true)
                        Text(verbatim: "Stellar → Monad").tag(false)
                    }
                    .pickerStyle(.segmented)
                    AmountInput(label: "USDC", text: $amount, code: "USDC", maxUnits: toStellar ? nil : store.account?.balance("USDC"))
                    if !toStellar && store.monad == nil {
                        TextField(tr("Monad address (0x…)"), text: $monadAddress).font(.body.monospaced()).autocorrectionDisabled()
                    }
                } footer: {
                    LiteParagraph(toStellar
                        ? tr("Your Monad wallet sends the USDC. It arrives on Stellar in about a minute.")
                        : tr("The USDC leaves Stellar now. You claim it on Monad with your Monad wallet once Circle confirms, in a few minutes."))
                }
                if let status {
                    Section(tr("Transfer")) {
                        LabeledContent(tr("Status"), value: status.status.replacingOccurrences(of: "_", with: " "))
                        if status.claim != nil, store.monad != nil {
                            LitePrimaryButton(title: tr("Claim on Monad"), busy: busy) { Task { await claim(status) } }
                        }
                        Button(tr("Refresh")) { Task { await refresh() } }
                    }
                }
                if let error { Section { LiteInlineError(message: error) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: toStellar ? tr("Move to Stellar") : tr("Review"), busy: busy, enabled: StellarAmount.parse(amount) != nil) { Task { await go() } }.padding()
            }
            .navigationTitle(tr("Bridge"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
            .sheet(item: $prepared) { action in
                ConfirmSheet(action: action) { results in
                    Task {
                        if let t = transfer, let hash = results.last?.hash { try? await store.bridgeSourceReported(id: t.id, hash: hash) }
                        await refresh()
                    }
                }
            }
        }
        .liteFormSheet()
    }

    private func go() async {
        guard let units7 = StellarAmount.parse(amount) else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            if toStellar {
                transfer = try await store.bridgeIn(amount6: units7 / 10) // Monad USDC has 6 decimals
                await refresh()
            } else {
                let dest = store.monad?.monadAddress ?? monadAddress
                let (action, t) = try await store.bridgeOutPlan(amount: units7 - units7 % 10, monadAddress: dest)
                transfer = t
                prepared = action
            }
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }

    private func refresh() async {
        guard let t = transfer else { return }
        status = try? await store.bridgeStatus(id: t.id)
    }

    private func claim(_ s: BridgeStatus) async {
        busy = true
        defer { busy = false }
        do {
            try await store.claimOnMonad(s)
            await refresh()
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }
}
