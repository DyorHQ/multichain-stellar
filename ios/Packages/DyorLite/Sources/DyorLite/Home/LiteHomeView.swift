import StellarKit
import SwiftUI

/// Stellar Home, in Monad Home's frame (design spec §3.3): the host's header, the balance card with the network chip
/// and the serif figure, four actions, My Holdings and Activity. Paused, the card says why and offers Monad; nothing on
/// Stellar locks (decision 6).
@MainActor
struct LiteHomeView: View {
    let session: LiteSession
    @Environment(\.liteChrome) private var chrome
    @Environment(\.liteStyle) private var style
    @Environment(\.scenePhase) private var scenePhase

    enum SheetKind: Identifiable {
        case send, receive, bridge
        case swap(buy: String?)

        var id: String {
            switch self {
            case .send: "send"
            case .receive: "receive"
            case .bridge: "bridge"
            case .swap(let buy): "swap.\(buy ?? "")"
            }
        }
    }

    /// A launch page in Home's stack.
    struct LaunchRoute: Hashable { let token: String }

    /// How often Home reads the account again while it is on screen (Monad Home's rhythm).
    static let pollInterval: Duration = .seconds(30)

    @State private var sheet: SheetKind?
    @State private var showSearch = false
    /// What the search picked, opened once it has closed.
    @State private var picked: LiteSearchSheet.Pick?
    @State private var path: [LaunchRoute] = []

    private var store: LiteStore? { session.store }
    private var isReady: Bool { session.home == .ready && store != nil }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    balanceCard
                    actions
                    if isReady, let store {
                        holdings(store)
                        activity(store)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.liteCanvas)
            .scrollIndicators(.hidden)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .safeAreaInset(edge: .top, spacing: 0) {
                chrome.header(LiteHeaderContext(openSearch: { showSearch = true },
                                                error: isReady ? store?.lastError : nil,
                                                updatedAt: isReady ? store?.updatedAt : nil))
            }
            .refreshable { await session.refreshHome() }
            // Read again every 30 s while Home is on screen, the session ready and the app in front, as Monad Home does:
            // in place (what was read stays until the new read replaces it), never a prompt.
            .task(id: isReady && scenePhase == .active) {
                guard isReady, scenePhase == .active else { return }
                while true {
                    try? await Task.sleep(for: Self.pollInterval)
                    guard !Task.isCancelled, session.home == .ready, let store else { return }
                    await store.refreshAll()
                }
            }
            .navigationDestination(for: LaunchRoute.self) { route in
                if let store { LaunchDetailView(token: route.token).environment(store) }
            }
            .sheet(item: $sheet) { kind in
                if let store {
                    sheetContent(kind).environment(store)
                }
            }
            .sheet(isPresented: $showSearch, onDismiss: openPicked) {
                LiteSearchSheet(store: isReady ? store : nil) { picked = $0 }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ kind: SheetKind) -> some View {
        switch kind {
        case .send: SendSheet()
        case .receive: ReceiveSheet(address: session.address ?? "", store: store)
        case .bridge: BridgeSheet()
        case .swap(let buy):
            if let buy {
                SwapSheet(initialSell: buy == "XLM" ? "USDC" : "XLM", initialBuy: buy)
            } else {
                SwapSheet()
            }
        }
    }

    private func openPicked() {
        guard let pick = picked else { return }
        picked = nil
        switch pick {
        case .holding(let asset): sheet = .swap(buy: asset)
        case .launch(let token): path.append(LaunchRoute(token: token))
        }
    }

    // MARK: Balance card

    /// The chip row as on Monad Home (spec §3.2): the host's chip with the whole row to itself (a spacer beside it
    /// would take half, and the Testnet badge would wrap), a 44 pt row, the card's top padding 10.
    private var chipRow: some View {
        chrome.networkChip()
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.bottom, -6)
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            chipRow
            switch session.home {
            case .ready, .loading: figure
            case .paused(let failure): paused(failure)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liteCardBackground()
    }

    /// The total in Monad Home's hero style; the placeholder until the balances and prices are read, never "$0.00".
    private var figure: some View {
        let total = isReady ? store?.totalValue : nil
        return VStack(alignment: .leading, spacing: 4) {
            hero(total ?? 0)
                .contentTransition(.numericText(value: total ?? 0))
                .unreadFigure(total == nil)
            LiteParagraph(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func hero(_ value: Double) -> some View {
        Text(verbatim: usd(value))
            .font(.system(size: 40, weight: .semibold, design: .serif))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// Testnet balances are valued at reference prices and say they have no value.
    private var caption: String {
        session.env.pinned.network.name == "testnet"
            ? tr("Valued at reference prices. Testnet assets have no value.")
            : tr("Valued at reference prices.")
    }

    /// Paused for maintenance, or this build is too old: why, and the way back to Monad, which always works.
    private func paused(_ failure: LiteSession.Failure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LiteInlineError(message: failure.errorDescription ?? "")
            LitePrimaryButton(title: tr("Switch to Monad"), action: chrome.switchToMonad)
        }
    }

    // MARK: Actions

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ForEach(LiteHomeAction.all) { tile($0) }
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { ForEach(LiteHomeAction.all.prefix(2)) { tile($0) } }
                GridRow { ForEach(LiteHomeAction.all.suffix(2)) { tile($0) } }
            }
        }
        .disabled(!isReady)
    }

    private func tile(_ action: LiteHomeAction) -> some View {
        LiteHomeTile(action: action) {
            switch action.id {
            case .bridge: sheet = .bridge
            case .deposit: sheet = .receive
            case .withdraw: sheet = .send
            case .swap: sheet = .swap(buy: nil)
            }
        }
    }

    // MARK: My Holdings

    private func holdings(_ store: LiteStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("My Holdings")).font(.headline)
            if let account = store.account {
                let rows = account.balances.filter { $0.enabled || $0.units > 0 }
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        LiteHoldingRow(code: row.code, name: LiteTitles.assetName(id: row.asset, name: row.name), amount: StellarAmount.format(row.units, maxFraction: 4),
                                       value: store.value(of: row).map(usd))
                        if index < rows.count - 1 || !store.positions.isEmpty { Divider().padding(.leading, 44) }
                    }
                    ForEach(Array(store.positions.enumerated()), id: \.element.id) { index, position in
                        LiteHoldingRow(code: position.code, name: tr("Earning on Blend"), amount: StellarAmount.format(position.supplied, maxFraction: 4), value: nil)
                        if index < store.positions.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
            } else if store.failed.contains(.account) {
                retryRow(store.lastError ?? "", store)
            } else {
                readingRow(tr("Reading your balances…"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liteCardBackground()
    }

    // MARK: Activity

    private func activity(_ store: LiteStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Activity")).font(.headline)
            switch Self.activityCard(store) {
            case .signIn:
                LiteSignInRow(session: session) { await store.refreshActivity() }
            case .empty:
                LiteParagraph(tr("Nothing yet. Fund your account or swap to get started."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .list:
                VStack(spacing: 0) {
                    let items = Array(store.activity.prefix(12))
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        LiteActivityRow(item: item)
                        if index < items.count - 1 { Divider() }
                    }
                }
            case .failed:
                retryRow(store.lastError ?? "", store)
            case .reading:
                readingRow(tr("Reading your activity…"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liteCardBackground()
    }

    /// What an Activity card shows (Home's, and the activity page's).
    enum ActivityCard: Equatable { case reading, signIn, empty, list, failed }

    /// From the store's last reads: DyorHQ's history with no session (an account reading in the public view) is the
    /// sign-in row, whatever a past session read; then the last list read, even after a read that failed; then the
    /// failure; then an empty list; else the read under way.
    static func activityCard(_ store: LiteStore) -> ActivityCard {
        if store.status(.activity) == .needsSignIn { return .signIn }
        if store.loaded.contains(.activity), !store.activity.isEmpty { return .list }
        if store.failed.contains(.activity) { return .failed }
        return store.loaded.contains(.activity) ? .empty : .reading
    }

    private func readingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    /// A read that failed, with Retry.
    private func retryRow(_ message: String, _ store: LiteStore) -> some View {
        HStack(alignment: .firstTextBaseline) {
            LiteInlineError(message: message)
            Spacer(minLength: 8)
            Button(tr("Retry")) { Task { await store.refreshAll() } }
                .font(.footnote.weight(.semibold))
        }
        .padding(.vertical, 12)
    }
}

/// One of the four Home actions: the first three are Monad Home's, for the same jobs. Adding cash is removed until
/// mainnet (decision 7).
struct LiteHomeAction: Identifiable {
    enum Kind { case bridge, deposit, withdraw, swap }
    let id: Kind
    let title: String
    let symbol: String

    static var all: [LiteHomeAction] {
        [
            LiteHomeAction(id: .bridge, title: tr("Bridge"), symbol: "point.3.connected.trianglepath.dotted"),
            LiteHomeAction(id: .deposit, title: tr("Deposit"), symbol: "creditcard"),
            LiteHomeAction(id: .withdraw, title: tr("Withdraw"), symbol: "arrow.up"),
            LiteHomeAction(id: .swap, title: tr("Swap"), symbol: "arrow.left.arrow.right"),
        ]
    }
}

/// A Home action tile, with Monad's `HomeAction` metrics: an SF Symbol over a label, filling its share of the row.
struct LiteHomeTile: View {
    let action: LiteHomeAction
    let perform: () -> Void
    /// One height for every symbol, so the tiles and their labels line up.
    @ScaledMetric(relativeTo: .body) private var symbolHeight: CGFloat = 24
    /// Off while the session is paused or still opening: drawn faded, so the card above says why.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: perform) {
            VStack(spacing: 6) {
                Image(systemName: action.symbol).font(.body.weight(.semibold)).frame(height: symbolHeight)
                Text(action.title).font(.caption).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.8)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.liteCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundStyle(.primary)
    }
}

/// A holding: the disc, the code and its name, the amount and its value.
struct LiteHoldingRow: View {
    let code: String
    let name: String
    let amount: String
    let value: String?

    var body: some View {
        HStack(spacing: 12) {
            AssetBadge(code: code, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: code).font(.subheadline.weight(.semibold))
                Text(verbatim: name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: amount).font(.subheadline.weight(.medium)).monospacedDigit()
                if let value { Text(verbatim: value).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// DyorHQ's history with no session (an account reading in the public view, §8): why, and the one button that signs in.
/// Nothing asks until it is tapped (`LiteSession.signIn()`: a passkey account's one ceremony); `then` reads the part
/// again once signed in.
struct LiteSignInRow: View {
    let session: LiteSession?
    let then: () async -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiteParagraph(tr("Sign in again to see your Stellar history."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await signIn() }
            } label: {
                if busy { ProgressView() } else { Text(tr("Sign in")) }
            }
            .buttonStyle(.bordered)
            .disabled(busy || session == nil)
            if let error { LiteInlineError(message: error) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func signIn() async {
        guard let session else { return }
        busy = true
        defer { busy = false }
        do {
            try await session.signIn()
            error = nil
            await then()
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }
}

/// An activity row: what happened, when, and its status as a word with a symbol.
struct LiteActivityRow: View {
    let item: StellarActivityItem
    @Environment(\.liteStyle) private var style

    /// The phone's own words for the item; else the server's, while none of its words is a stand-in; else "Transaction".
    static func title(_ item: StellarActivityItem) -> String {
        LiteTitles.activity(item) ?? LiteFormat.sentence(item.summary) ?? tr("Transaction")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.title(item)).font(.subheadline).lineLimit(2)
                Text(verbatim: time).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            status
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var time: String {
        guard let date = item.at.liteDate else { return String(item.at.prefix(16)).replacingOccurrences(of: "T", with: " ") }
        return date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(LiteL10n.locale))
    }

    @ViewBuilder private var status: some View {
        // Status words of their own (keys apart from the buttons' "Done"), so a language can word each as a state.
        switch Self.outcome(item.status) {
        case .done:
            Label(LiteL10n.string(LocalizedStringResource("activity.done", defaultValue: "Done", bundle: LiteL10n.lite)), systemImage: "checkmark")
                .foregroundStyle(.secondary)
                .font(.caption.weight(.semibold))
        case .pending:
            Label(LiteL10n.string(LocalizedStringResource("activity.pending", defaultValue: "Pending", bundle: LiteL10n.lite)), systemImage: "clock")
                .foregroundStyle(.secondary)
                .font(.caption.weight(.semibold))
        case .failed:
            Label(LiteL10n.string(LocalizedStringResource("activity.failed", defaultValue: "Failed", bundle: LiteL10n.lite)), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(style.negative)
                .font(.caption.weight(.semibold))
        }
    }

    enum Outcome { case done, pending, failed }

    /// The server's statuses (transactions and transfers) as three words.
    static func outcome(_ status: String) -> Outcome {
        switch status {
        case "success", "completed": .done
        case "failed", "error", "expired", "refunded": .failed
        default: .pending
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
                    Picker(tr("Pay with"), selection: $sell) { ForEach(choices, id: \.self) { Text(verbatim: choiceName($0)).tag($0) } }
                    AmountInput(label: tr("Amount"), text: $amount, code: code(sell), maxUnits: store.account?.balance(sell))
                    Button {
                        let s = sell
                        sell = buy
                        buy = s
                    } label: { Label(tr("Flip"), systemImage: "arrow.up.arrow.down") }
                    Picker(tr("Receive"), selection: $buy) { ForEach(choices, id: \.self) { Text(verbatim: choiceName($0)).tag($0) } }
                }
                if let quote {
                    Section(tr("Best price")) {
                        LabeledContent(tr("You get about"), value: "\(StellarAmount.format(quote.best.amountOut)) \(code(buy))")
                        LabeledContent(tr("At least"), value: "\(StellarAmount.format(quote.best.minOut ?? quote.best.amountOut)) \(code(buy))")
                        LabeledContent(tr("Route"), value: LiteTitles.venue(quote.best.venue))
                        ForEach(quote.alternatives, id: \.venue) { alt in
                            LabeledContent(LiteTitles.venue(alt.venue), value: "\(StellarAmount.format(alt.amountOut)) \(code(buy))").foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Section { LiteInlineError(message: error) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: quote == nil ? tr("Get price") : tr("Review swap"), busy: busy, enabled: StellarAmount.parse(amount) != nil && sell != buy) {
                    Task { await next() }
                }
                .padding()
            }
            .navigationTitle(tr("Swap"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
            .onChange(of: amount) { _, _ in quote = nil }
            .onChange(of: sell) { _, _ in quote = nil }
            .onChange(of: buy) { _, _ in quote = nil }
            .onAppear {
                sell = initialSell
                buy = initialBuy
            }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in dismiss() } }
        }
        .liteFormSheet()
    }

    private var choices: [String] {
        var ids = ["XLM", "USDC"]
        if store.isTestnet { ids.append("BUSDC") }
        ids += store.account?.balances.filter { $0.classic == nil }.map(\.asset) ?? []
        for id in [initialSell, initialBuy] where !ids.contains(id) { ids.append(id) }
        return ids
    }

    private func code(_ id: String) -> String { store.code(id) }

    /// A choice's name in the pickers: its code, and its name as well when another choice has the same code (Blend's
    /// test USDC beside the wallet's USDC).
    private func choiceName(_ id: String) -> String {
        let code = code(id)
        guard choices.filter({ self.code($0) == code }).count > 1 else { return code }
        return "\(code) · \(LiteTitles.assetName(id: id, name: store.asset(id)?.name ?? code))"
    }

    private func next() async {
        guard let units = StellarAmount.parse(amount) else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            if let quote {
                prepared = try await store.swapPlan(quote)
            } else {
                quote = try await store.swapQuote(sell: sell, buy: buy, amount: units, slippageBps: 100)
            }
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }
}

// ------------------------------------------------------------------------------------------------ withdraw & deposit

/// Withdraw: sends an asset to another Stellar address (an exchange, a friend).
struct SendSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var asset: String
    @State private var to = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?

    /// `asset`: the one to send at first (a registry id); XLM when nil.
    init(asset: String? = nil) {
        _asset = State(initialValue: asset ?? "XLM")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(tr("Asset"), selection: $asset) {
                        ForEach(store.account?.balances.filter { $0.enabled } ?? []) { Text(verbatim: $0.code).tag($0.asset) }
                    }
                    TextField(tr("To (G… address)"), text: $to).font(.body.monospaced()).autocorrectionDisabled()
                    AmountInput(label: tr("Amount"), text: $amount, code: store.account?.balances.first { $0.asset == asset }?.code ?? "", maxUnits: store.account?.balance(asset))
                    TextField(tr("Memo (optional)"), text: $memo)
                } footer: {
                    LiteParagraph(tr("Some exchanges and cash providers need a memo. Use the one they give you."))
                }
                if let error { Section { LiteInlineError(message: error) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: tr("Review"), busy: busy, enabled: StrKey.isValid(.accountID, to) && StellarAmount.parse(amount) != nil) {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            prepared = try await store.sendPlan(asset: asset, to: to, amount: StellarAmount.parse(amount) ?? 0, memo: memo.isEmpty ? nil : memo, memoType: memo.allSatisfy(\.isNumber) && !memo.isEmpty ? "id" : "text")
                        } catch { self.error = LiteErrorText.describe(error) }
                    }
                }
                .padding()
            }
            .navigationTitle(tr("Withdraw"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in dismiss() } }
        }
        .liteFormSheet()
    }
}

/// Deposit: the account's Stellar address and its QR code. Receiving needs nothing but the address, so it shows before
/// the account's figures are read too (`store` nil). On testnet, an account that never had Friendbot's test XLM (one
/// that existed before it came to DyorHQ) also gets "Fund with Friendbot", once: the row shows only while the server
/// says the claim is open (`firstFunding.faucet.claimed` false), in the amount it gives (decision 7).
struct ReceiveSheet: View {
    let address: String
    let store: LiteStore?
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var funding = false
    @State private var funded = false
    @State private var error: String?
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var bottomInset: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                QRCodeView(text: address).frame(width: 220, height: 220)
                LiteAddressText(address: address)
                    .font(.footnote.monospaced())
                    .multilineTextAlignment(.center)
                Button(copied ? tr("Copied") : tr("Copy address")) {
                    copyToPasteboard(address)
                    copied = true
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                LiteParagraph(tr("Send only Stellar assets to this address. To move USDC from Monad, use Bridge on Home."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let store, store.canClaimFriendbot, let amount = Self.faucetAmount(store.config) {
                    friendbot(store, amount: amount)
                } else if funded {
                    Label(tr("Funded with Friendbot"), systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let error { LiteInlineError(message: error) }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .top, spacing: 0) {
            LiteSheetHeader(title: tr("Deposit")) { dismiss() }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
        // Sized to its content, as the app's network sheet is: nothing cut off, and `.large` with the content scrolling
        // once it outgrows 85% of the screen (accessibility sizes).
        .presentationDetents(LiteSheetHeight.fits(fitted) ? [.height(fitted)] : [.large])
        .presentationDragIndicator(.visible)
        .liteFormSheet()
    }

    /// "Fund with Friendbot" and what it brings, once. Once claimed, the account is read again and the row goes.
    private func friendbot(_ store: LiteStore, amount: String) -> some View {
        VStack(spacing: 6) {
            Button {
                Task { await fund(store) }
            } label: {
                if funding { ProgressView() } else { Label(tr("Fund with Friendbot"), systemImage: "drop") }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(funding)
            Text(tr("Get \(amount) free test XLM, once"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fund(_ store: LiteStore) async {
        funding = true
        defer { funding = false }
        error = nil
        do {
            try await store.faucet()
            funded = true
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }

    /// The header, the content and the home indicator's inset; about 560 until measured.
    private var fitted: CGFloat {
        contentHeight > 0 ? headerHeight + contentHeight + bottomInset : 560
    }

    /// Friendbot's grant, as the server's config gives it (`faucet.amount`, in XLM), in the current language's digits;
    /// nil off testnet and from servers that don't say.
    static func faucetAmount(_ config: LiteConfig?) -> String? {
        guard let text = config?.faucet?.amount, let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return amount.formatted(.number.locale(LiteL10n.locale))
    }
}
