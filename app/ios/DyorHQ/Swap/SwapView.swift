import BigInt
import DyorKit
import SwiftUI

/// Spot swaps. Every venue is asked at once and each one's quote shows as it arrives, the best so far preselected; the
/// person can still pick another. Review opens once every venue has answered (`SwapModel.selectedQuote`).
struct SwapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @State private var model = SwapModel()
    @State private var picking: SwapModel.Side?
    /// The quote under review, frozen when the sheet opens. Quotes refresh every 15 s, and the sheet builds its plan
    /// once, so reading the live quote would let the details (and a passkey session's intent) drift from what's signed.
    @State private var reviewing: SwapReview?
    @State private var showSlippage = false
    @State private var historyWindow: SwapHistoryService.Window = .day
    @State private var swapHistory: [SwapHistoryItem] = []
    @State private var loadingHistory = false

    var body: some View {
        NavigationStack {
            List {
                paySection
                flipRow
                receiveSection
                actionSection
                curveSection
                quotesSection
                activitySection
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(tr("Trade"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { TradeModeSwitcher() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.selection(); showSlippage = true } label: {
                        Label("Slippage \(NumberStyle.basisPoints(model.slippageBps))", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .keyboardDoneButton()
            .sheet(item: $picking) { side in
                TokenPickerSheet(selected: side == .pay ? model.tokenIn : model.tokenOut, balances: model.balances, universe: KnownTokenStore.universe(owner: session.address),
                                 unverified: KnownTokenStore.unverified(owner: session.address)) { token in
                    // Remember any token the user picks (a pasted ERC-20 included) so it shows a balance and price in
                    // holdings and the picker from now on, not only after a completed swap.
                    KnownTokenStore.add(token, owner: session.address)
                    model.select(token, for: side)
                }
            }
            .sheet(item: $reviewing) { review in confirmation(review) }
            .sheet(isPresented: $showSlippage) { SlippageSheet(slippageBps: $model.slippageBps) }
            .task(id: session.address) {
                model.account = session.address
                // Kuru Flow's access token for this wallet, asked for as Swap opens, so the first quote doesn't wait for it.
                async let prepared: Void = env.swap.prepare(for: SwapModel.quoteAccount(session.address))
                await model.refreshBalances(env: env, address: session.address)
                await prepared
            }
            .task(id: model.quoteKey) { await model.quote(env: env, account: model.account) }
            .onChange(of: router.pendingSwap?.tokenOut) { _, _ in applyPending() }
            .onAppear { applyPending() }
        }
    }

    /// All the wallet's swaps over the selected range (not just the paying asset) — recorded swaps merged with an
    /// on-chain Transfer scan that backfills older ones, newest first.
    @ViewBuilder private var activitySection: some View {
        if session.canSign {
            Section {
                Picker("Range", selection: $historyWindow) {
                    ForEach(SwapHistoryService.Window.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if loadingHistory, swapHistory.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading swaps…").font(.subheadline).foregroundStyle(.secondary) }
                } else if swapHistory.isEmpty {
                    Text("No swaps in this range yet.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(swapHistory) { SwapHistoryRow(item: $0) }
                }
            } header: {
                Text("Swap History")
            }
            // The history fills in behind the screen (`HistoryModel`): the list follows it.
            .task(id: "\(historyWindow.rawValue)-\(session.address?.hex ?? "")-\(env.history.version)") { await loadHistory() }
        }
    }

    private func loadHistory() async {
        guard let address = session.address else { swapHistory = []; return }
        loadingHistory = true
        defer { loadingHistory = false }
        let tokens = Dictionary(KnownTokenStore.universe(owner: address).map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        let cutoff = Date().addingTimeInterval(-historyWindow.seconds)
        // The wallet's swaps from the history model (no scan of its own), within the window.
        let scanned = env.history.wallet == address ? env.history.snapshot.swaps.filter { $0.time >= cutoff } : []
        var items: [SwapHistoryItem] = []
        var seen = Set<String>()
        // Recorded swaps first: exact legs, and they include native-MON legs the Transfer scan can't see.
        for record in ActivityLog.all(owner: address) where record.kind == .swap && record.time >= cutoff {
            guard let hashHex = record.txHashHex, seen.insert(hashHex).inserted else { continue }
            items.append(SwapHistoryItem(id: hashHex, hash: record.txHash, time: record.time, text: record.subtitle))
        }
        // On-chain reconstruction backfills swaps made before recording (or on another device).
        for swap in scanned where seen.insert(swap.hash.hexString).inserted {
            items.append(SwapHistoryItem(id: swap.hash.hexString, hash: swap.hash, time: swap.time, text: SwapHistoryItem.describe(swap, tokens: tokens)))
        }
        swapHistory = items.sorted { $0.time > $1.time }
    }

    private var paySection: some View {
        Section {
            tokenRow(side: .pay, token: model.tokenIn)
            AmountField(title: "0" as String, text: $model.amountText, token: nil) {
                Haptics.selection(); useMax()
            }
            percentRow
        } header: {
            Text("You Pay")
        } footer: {
            HStack {
                if let balance = model.balances[model.tokenIn.address] {
                    Text("Balance: \(NumberStyle.units(balance, decimals: model.tokenIn.decimals)) \(model.tokenIn.symbol)")
                }
                Spacer()
                if let usd = model.payUSD { Text(PriceFormat.usdValue(usd)) }
            }
            // With the header below trimmed to match (`receiveSection`), the flip button sits 10 pt from the balance
            // line and 10 pt from "You Receive".
            .padding(.bottom, -8)
        }
        .listSectionSpacing(0)
    }

    /// Quick-size the pay amount to a share of the wallet balance — 25 / 50 / 75 / 100%. On a full send of native
    /// MON the swap's network fee is kept back.
    private var percentRow: some View {
        HStack(spacing: 8) {
            ForEach([25, 50, 75, 100], id: \.self) { pct in
                Button {
                    Haptics.selection()
                    if pct == 100 { useMax() } else { model.applyPercent(Double(pct)) }
                } label: {
                    Text(verbatim: "\(pct)%")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .disabled((model.balances[model.tokenIn.address] ?? 0) == 0)
        .listRowSeparator(.hidden)
    }

    private func useMax() {
        Task { await model.applyMax(env: env, account: session.address) }
    }

    /// The flip button between the two cards, as tight as the list allows and the same gap above and below: no section
    /// spacing on either side of it, and a row exactly the button's height.
    private var flipRow: some View {
        Section {
            HStack {
                Spacer()
                Button { Haptics.selection(); model.flip() } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.body.weight(.semibold))
                        .padding(10)
                        .background(Color(.secondarySystemGroupedBackground), in: Circle())
                }
                .accessibilityLabel("Swap direction")
                Spacer()
            }
            .frame(height: 40)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 0)
    }

    /// The swap's action, in the page right under what it trades. Pinned to the bottom it sat on a bar over the quotes
    /// and the history.
    private var actionSection: some View {
        Section {
            // Disabled while the balance can't cover the input: the title says why (UI-4).
            PrimaryButton(title: model.actionTitle, isBusy: false, isDisabled: model.selectedQuote == nil || model.insufficient) { reviewing = model.review }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private var receiveSection: some View {
        Section {
            tokenRow(side: .receive, token: model.tokenOut)
            HStack {
                if let quote = model.shownQuote {
                    AmountText(amount: quote.amountOut, token: model.tokenOut, font: .title2.weight(.medium))
                } else if model.awaitingQuote {
                    ProgressView().controlSize(.small)
                    Text("Finding the best price").foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "0").font(.title2.weight(.medium)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            // While venues are still asked, the amount above is the best of those that answered — or the venue picked,
            // which is not called the best — said so until the others have answered too, and Review waits for them
            // (`SwapModel.selectedQuote`).
            if let stillAsked = model.venuesStillAsked {
                Group {
                    if model.showsBestSoFar {
                        Paragraph("Best price so far. Still checking \(stillAsked) more venues.")
                    } else {
                        Paragraph("Still checking \(stillAsked) more venues.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden, edges: .top)
            }
        } header: {
            Text("You Receive")
                .padding(.top, -10) // the same 10 pt from the flip button as the balance line above it (`paySection`)
        } footer: {
            HStack {
                if let balance = model.balances[model.tokenOut.address] {
                    Text("Balance: \(NumberStyle.units(balance, decimals: model.tokenOut.decimals)) \(model.tokenOut.symbol)")
                }
                Spacer()
                if let usd = model.receiveUSD { Text(PriceFormat.usdValue(usd)) }
            }
        }
    }

    /// Swap's "no venue" state when a side is still on a launchpad's bonding curve (the live launchpad's or a retired
    /// one's): no venue routes a curve, so rather than a dead end it says where the coin trades and opens its Launch page
    /// (by reference when its launch couldn't be read), or, when the check failed, offers to check again or the Launch
    /// tab, where a retired coin's holder finds it under "Your Sell-Only Coins".
    @ViewBuilder private var curveSection: some View {
        if model.amountIn > 0, let curve = model.currentCurve, let notice = curve.route.notice {
            Section {
                Label(notice, systemImage: "arrow.up.right.circle").font(.subheadline).foregroundStyle(.secondary)
                if let title = curve.route.actionTitle(curve.token.symbol) {
                    Button(title, systemImage: "arrow.up.right.circle") { router.openLaunchPage(for: curve.route) }
                } else {
                    Button("Check Again", systemImage: "arrow.clockwise") { Task { await model.recheckCurve(env: env) } }
                        .disabled(model.checkingCurve)
                    Button("Open the Launch Tab", systemImage: "flame") { router.openLaunchTab() }
                }
            }
        }
    }

    @ViewBuilder private var quotesSection: some View {
        if let result = model.currentResult, model.amountIn > 0 {
            Section {
                ForEach(result.quotes) { quote in
                    Button { Haptics.selection(); model.pick(quote.venue) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(quote.venue.displayName).font(.headline)
                                    // Best of every venue only once they all answered: until then it is the best so far.
                                    if result.isFinal, quote.venue == result.quotes.first?.venue {
                                        Text("Best", comment: "Badge on the venue with the best quote [tight]").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.positive.opacity(0.15), in: Capsule()).foregroundStyle(Color.positive)
                                    }
                                }
                                Text(quote.route).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                AmountText(amount: quote.amountOut, token: model.tokenOut, font: .body.weight(.medium))
                                if let impact = quote.priceImpactBps {
                                    Text("Impact \(NumberStyle.basisPoints(abs(impact)))").font(.footnote).foregroundStyle(abs(impact) > 100 ? Color.attention : .secondary)
                                }
                            }
                            Image(systemName: model.selectedVenue == quote.venue ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.selectedVenue == quote.venue ? Color.accentColor : Color(.tertiaryLabel))
                        }
                    }
                    .foregroundStyle(.primary)
                }
                ForEach(result.errors.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { venue in
                    HStack {
                        Text(venue.displayName).foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: result.errors[venue] ?? "").font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.trailing)
                    }
                }
                // The venues not heard from yet, each until it answers or runs out of time (`SwapEngine.quoteTimeout`).
                ForEach(result.pending, id: \.self) { venue in
                    HStack(spacing: 6) {
                        Text(venue.displayName).foregroundStyle(.secondary)
                        Spacer()
                        ProgressView().controlSize(.mini)
                        Text("Checking…", comment: "Beside a swap venue that hasn't answered yet: its quote is still being asked for [tight]")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            } header: {
                HStack {
                    Text("Quotes")
                    Spacer()
                    if model.quoting { ProgressView().controlSize(.mini) }
                }
            } footer: {
                if let quote = model.selectedQuote {
                    Paragraph("Minimum received \(NumberStyle.units(quote.minOut, decimals: model.tokenOut.decimals)) \(model.tokenOut.symbol) at \(NumberStyle.basisPoints(model.slippageBps)) slippage. Quotes refresh every 15 seconds.")
                }
            }
        } else if let error = model.currentError {
            Section { InlineError(message: error) }.listRowBackground(Color.clear)
        }
    }

    private func tokenRow(side: SwapModel.Side, token: Token) -> some View {
        Button { Haptics.selection(); picking = side } label: {
            HStack(spacing: 12) {
                TokenLogo(token: token, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(token.symbol).font(.headline)
                        TokenBadgeView(token: token, receivedUnasked: KnownTokenStore.isUnverified(token.address, owner: session.address))
                    }
                    Text(token.displayName).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(side == .pay ? Text("Pay with \(token.symbol)") : Text("Receive \(token.symbol)"))
        .accessibilityHint("Choose a different token")
    }

    private func confirmation(_ review: SwapReview) -> some View {
        SwapConfirmation(review: review, onDone: {
            model.amountText = ""
            Task { await model.refreshBalances(env: env, address: session.address) }
        }, onCompleted: { hash in
            // At settlement, not on Done (GL-3). Record the swap so it shows in Swap History and Recent Activity with
            // its exact legs (including a native MON leg, which an on-chain Transfer scan can't recover): the ones
            // reviewed and signed.
            let text = "\(NumberStyle.units(review.amountIn, decimals: review.tokenIn.decimals, compact: true)) \(review.tokenIn.symbol) → \(NumberStyle.units(review.quote.amountOut, decimals: review.tokenOut.decimals, compact: true)) \(review.tokenOut.symbol)"
            let usd = [review.payUSD, review.receiveUSD].compactMap { $0 }.first { $0 > 0 }
            ActivityLog.record(ActivityRecord(kind: .swap, title: tr("Swapped"), subtitle: text, hash: hash, usd: usd), owner: session.address)
            // Remember both sides so they show in holdings and the picker even if they aren't curated: the token
            // just acquired, and the one paid with (a partial swap leaves a balance still worth showing).
            KnownTokenStore.add(review.tokenOut, owner: session.address)
            KnownTokenStore.add(review.tokenIn, owner: session.address)
            // Bought here on purpose: no longer an unverified token that merely arrived in the wallet (IOST-12).
            KnownTokenStore.markChosen(review.tokenOut.address, owner: session.address)
            if settings.notificationsEnabled, settings.notifyFills {
                Notifications.swapped(review.amountIn, review.tokenIn, review.quote.amountOut, review.tokenOut)
            }
        })
    }

    private func applyPending() {
        guard let pending = router.pendingSwap else { return }
        router.pendingSwap = nil
        // A retired cohort's Moment coin never becomes a side (Router.openSwap refuses it first).
        guard SwapEngine.isTradablePair(pending.tokenIn, pending.tokenOut) else { return }
        if let tokenIn = pending.tokenIn { model.tokenIn = tokenIn }
        if let tokenOut = pending.tokenOut { model.tokenOut = tokenOut }
    }
}

/// What the review sheet shows and signs, frozen when Review is tapped: the quote with the request it answers (the
/// pair, amount and slippage it was quoted for, and their dollar values then). Quotes refresh every 15 s and a Max can
/// land late, but the sheet builds its plan once, so everything it shows, declares to a passkey session and records
/// comes from here — never from the live form.
struct SwapReview: Identifiable {
    let id = UUID()
    let quote: VenueQuote
    let tokenIn: Token
    let tokenOut: Token
    let amountIn: BigUInt
    let slippageBps: Int
    let payUSD: Double?
    let receiveUSD: Double?
}

/// Builds the plan for the reviewed quote, then hands it to the shared confirmation sheet.
private struct SwapConfirmation: View {
    let review: SwapReview
    let onDone: () -> Void
    var onCompleted: ((Data) -> Void)? = nil
    @Environment(Session.self) private var session

    var body: some View {
        let quote = review.quote
        ConfirmationSheet(title: "Review Swap", confirmTitle: LocalizedStringResource("Swap", comment: "Button: make the swap the review shows (a verb)"), build: {
            guard let address = session.address else { throw SessionError.readOnly }
            return try await quote.build(address)
        }, onDone: onDone, onCompleted: onCompleted, intent: intent) {
            DetailRow("You pay", verbatim: "\(NumberStyle.units(review.amountIn, decimals: review.tokenIn.decimals)) \(review.tokenIn.symbol)")
            DetailRow("You receive", verbatim: "\(NumberStyle.units(quote.amountOut, decimals: review.tokenOut.decimals)) \(review.tokenOut.symbol)")
            DetailRow("Minimum received", verbatim: "\(NumberStyle.units(quote.minOut, decimals: review.tokenOut.decimals)) \(review.tokenOut.symbol)")
            DetailRow("Venue", quote.venue.displayName)
            DetailRow("Route", quote.route)
            DetailRow("Slippage", NumberStyle.basisPoints(review.slippageBps))
        }
    }

    /// A swap (or wrap) of exactly what's shown, for the quoted output, valued at the input's price.
    private var intent: Mera.Intent {
        .swap(venue: review.quote.venue, pay: .init(token: review.tokenIn.address, amount: review.amountIn),
              receive: .init(token: review.tokenOut.address, amount: review.quote.amountOut), usd: review.payUSD)
    }
}

@Observable
@MainActor
final class SwapModel {
    enum Side: Identifiable { case pay, receive; var id: Self { self } }

    var tokenIn: Token = .mon
    var tokenOut: Token = .usdc
    var amountText = ""
    var slippageBps = 50
    /// The connected wallet, which the quotes are asked for (Kuru Flow's calldata pays it), set by the view. Part of
    /// `quoteKey`: signing in on this screen asks every venue again for the new wallet, and no quote made for another
    /// one stays reviewable.
    var account: Address?
    /// The venue selected, and whether the person picked it (`VenueSelection`): until a venue row is tapped it follows the
    /// best quote, so far or final; a pick is kept while a round is under way, and given back to the best only by a final
    /// answer that doesn't quote it. Set through `pick(_:)`, and by every answer (`VenueSelection.following`).
    private(set) var selection = VenueSelection()
    var selectedVenue: Venue? { selection.venue }
    private(set) var balances: [Address: BigUInt] = [:]
    private(set) var prices: [Address: PriceInfo] = [:]
    /// The venues' answer: as it fills in on a first round for what is on screen, then final (`QuoteResult.isFinal`).
    private(set) var result: QuoteResult?
    /// The `quoteKey` that `result` and `error` answer. The amount, pair, slippage or wallet can change while a re-quote
    /// is on its way (400 ms debounce, then every venue): until it lands, the old answer is kept out of sight and can't
    /// be reviewed (`currentResult`, `selectedQuote`).
    private(set) var resultKey: String?
    private(set) var quoting = false
    private(set) var error: String?
    /// When no venue routes the pair: the side still on a launchpad's bonding curve and where it trades instead
    /// (`LaunchpadService.curveRoute(among:)`), for the key `curveKey` answers. Nil when no side is on a curve.
    private(set) var curve: CurveCoinRoute?
    /// The `quoteKey` that `curve` answers. The curve check runs after that key's quotes are on screen, never holding
    /// back the "no venue" answer, so for a moment `curve` may still answer an earlier key (kept out of sight).
    private(set) var curveKey: String?
    private(set) var checkingCurve = false

    var amountIn: BigUInt { Amount.parse(amountText, decimals: tokenIn.decimals) ?? 0 }
    var quoteKey: String { "\(tokenIn.address.hex)-\(tokenOut.address.hex)-\(amountIn)-\(slippageBps)-\(account?.hex ?? "")" }
    /// Who a quote is asked for: the connected wallet, or a placeholder while none is (nothing can be signed then).
    static func quoteAccount(_ account: Address?) -> Address {
        account ?? Address(literal: "0x000000000000000000000000000000000000dEaD")
    }
    /// A quote for what is on screen is on its way: the fetch, or the debounce before it after an edit (the old answer
    /// is already out of sight).
    var awaitingQuote: Bool { amountIn > 0 && tokenIn != tokenOut && (quoting || resultKey != quoteKey) }
    /// `result`, when it answers what is on screen now.
    var currentResult: QuoteResult? { resultKey == quoteKey ? result : nil }
    /// `error`, when it answers what is on screen now.
    var currentError: String? { resultKey == quoteKey ? error : nil }
    /// `curve`, when it answers what is on screen now.
    var currentCurve: CurveCoinRoute? { resultKey == quoteKey && curveKey == quoteKey ? curve : nil }
    /// The quote the screen shows for what is on screen now: the selected venue's once it has answered, else the best —
    /// of the venues that answered so far while a first round fills in, or of them all once it is final
    /// (`VenueSelection.shown(in:)`).
    var shownQuote: VenueQuote? {
        guard let result = currentResult, amountIn > 0 else { return nil }
        return selection.shown(in: result)
    }
    /// The quote Review takes: `shownQuote`, once every venue has answered for what is on screen now — this pair,
    /// amount, slippage and wallet (`quoteKey`, `QuoteResult.isFinal`). Nil while any venue is still being asked, so
    /// neither a best so far, which a slower venue may still beat, nor an answer to earlier inputs can be reviewed or
    /// signed.
    var selectedQuote: VenueQuote? {
        guard currentResult?.isFinal == true else { return nil }
        return shownQuote
    }
    /// How many venues are still being asked while a quote is on screen; nil once the answer is final, or while no venue
    /// has quoted yet ("Finding the best price").
    var venuesStillAsked: Int? {
        guard let result = currentResult, !result.isFinal, shownQuote != nil else { return nil }
        return result.pending.count
    }
    /// The quote on screen is the best of the venues that answered so far: not when it is a picked venue's that another
    /// venue beats.
    var showsBestSoFar: Bool {
        guard let shown = shownQuote, let best = currentResult?.quotes.first else { return false }
        return shown.venue == best.venue
    }
    /// What the review sheet shows and signs, frozen when Review is tapped (nil without a final quote).
    var review: SwapReview? {
        guard let quote = selectedQuote else { return nil }
        return SwapReview(quote: quote, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, slippageBps: slippageBps,
                          payUSD: payUSD, receiveUSD: receiveUSD)
    }
    var payUSD: Double? { prices[tokenIn.address].map { Amount.units(amountIn, decimals: tokenIn.decimals) * $0.usd } }
    var receiveUSD: Double? {
        guard let quote = shownQuote, let price = prices[tokenOut.address] else { return nil }
        return Amount.units(quote.amountOut, decimals: tokenOut.decimals) * price.usd
    }
    /// The input is more than the wallet holds (a balance that couldn't be read doesn't count).
    var insufficient: Bool { balances[tokenIn.address].map { amountIn > $0 } ?? false }
    var actionTitle: String {
        if amountIn == 0 { return tr("Enter an Amount") }
        if insufficient { return tr("Insufficient \(tokenIn.symbol)") }
        if SwapEngine.isWrap(tokenIn, tokenOut) { return tokenIn.isNative ? tr("Wrap MON") : tr("Unwrap WMON") }
        return tr("Review Swap")
    }

    /// The person picked `venue` (a venue row tapped): it stays selected until a final answer doesn't quote it.
    func pick(_ venue: Venue) {
        selection = VenueSelection(venue: venue, picked: true)
    }

    func select(_ token: Token, for side: Side) {
        // Trading a retired cohort's Moment coin is closed: the picker never offers one, and it is refused here too.
        guard SwapEngine.isTradable(token) else { return }
        let before = (tokenIn, tokenOut)
        switch side {
        case .pay:
            if token == tokenOut { tokenOut = tokenIn }
            tokenIn = token
        case .receive:
            if token == tokenIn { tokenIn = tokenOut }
            tokenOut = token
        }
        // Re-picking the same token changes nothing: its quotes stay (the running refresh keeps its key).
        guard (tokenIn, tokenOut) != before else { return }
        result = nil
        curve = nil
        selection.picked = false
    }

    func flip() {
        // The quote's output becomes the new input (the best so far will do): read it before the swap makes it answer
        // another pair.
        let carried = shownQuote
        swap(&tokenIn, &tokenOut)
        if let carried { amountText = Amount.exact(Amount.roundedDown(carried.amountOut, decimals: tokenIn.decimals), decimals: tokenIn.decimals) }
        result = nil
        curve = nil
        selection.picked = false
    }

    /// Set the pay amount to `pct`% of the wallet balance. A full send of native MON keeps Monad's fallback fee back;
    /// the Max buttons use `applyMax`, which reads the real one. A share (or MON after its fee) is rounded down to six
    /// significant digits (`Amount.roundedDown`); 100% of a token stays exact, so all of it can be swapped.
    func applyPercent(_ pct: Double) {
        guard let balance = balances[tokenIn.address], balance > 0 else { return }
        var amount = balance
        if pct < 100 {
            amount = Amount.roundedDown(balance * BigUInt(UInt(pct)) / 100, decimals: tokenIn.decimals)
        } else if tokenIn.isNative {
            amount = Amount.roundedDown(NetworkFeeReserve.spendable(balance: balance, reserve: NetworkFeeReserve.monadFallback), decimals: tokenIn.decimals)
        }
        amountText = Amount.exact(amount, decimals: tokenIn.decimals)
    }

    /// Max (MERA-PLAN §5). For native MON: the balance less what the swap can be charged up front — the gas limit of
    /// the route on screen (estimated for this account) or a routed swap's budget, × (2 × base fee + tip) with headroom,
    /// 0.06 MON when the fee can't be read. Zero when the fee takes it all. Any other token: the whole balance.
    func applyMax(env: AppEnvironment, account: Address?) async {
        guard tokenIn.isNative, let balance = balances[tokenIn.address], balance > 0 else { applyPercent(100); return }
        let token = tokenIn
        var route: TransactionRequest?
        if let account, let quote = shownQuote, let steps = try? await quote.build(account) {
            route = steps.lazy.compactMap { try? $0.request(at: Date()) }.first { $0.value > 0 }
        }
        let amount = await env.sender.maxValue(balance: balance, like: route, from: account, budget: NetworkFeeReserve.swapGasLimit)
        // The pair or the balance changed while the fee was read: that Max no longer applies.
        guard tokenIn == token, balances[token.address] == balance else { return }
        // Rounded down: a sliver more stays back with the fee reserve, and the field reads "2.16254", not 18 decimals.
        amountText = Amount.exact(Amount.roundedDown(amount, decimals: token.decimals), decimals: token.decimals)
    }

    func refreshBalances(env: AppEnvironment, address: Address?) async {
        let universe = KnownTokenStore.universe(owner: address)
        async let priceTask = env.prices.prices(for: universe)
        if let address { balances = (try? await ERC20.balances(of: universe, owner: address, rpc: env.rpc, multicall: env.multicall)) ?? [:] }
        prices = (try? await priceTask) ?? prices
    }

    /// Checks the pair's sides again after the curve check failed (`CurveRoute.unchecked`), for what is on screen now.
    func recheckCurve(env: AppEnvironment) async {
        guard currentCurve != nil, !checkingCurve else { return }
        let key = quoteKey
        checkingCurve = true
        defer { checkingCurve = false }
        let fresh = await env.launchpad.curveRoute(among: [tokenOut, tokenIn])
        guard key == quoteKey, resultKey == key else { return }
        curve = fresh
        curveKey = key
    }

    /// Debounced by the caller's `.task(id:)`: the task is cancelled and restarted on every keystroke.
    /// `exactApprovals`: every account's plans approve exactly the input (`SwapRequest.exactApprovals`) — an ERC-20
    /// into Uniswap v4 costs one approval more per swap, and no unlimited Permit2 allowance is left standing (IOST-14).
    ///
    /// A first round for what is on screen shows each venue's quote as it arrives (`SwapEngine.quoteUpdates`): the best
    /// so far, and the venues still asked. Review waits for the final answer (`selectedQuote`). The re-quote every 15 s
    /// keeps the final answer on screen until its own is final, then replaces it whole, so Review never goes dark for a
    /// refresh and never takes a half-refreshed answer. A venue the person picked stays selected through a round's
    /// answers until its final one (`VenueSelection.following`): Review never takes a venue they didn't pick.
    func quote(env: AppEnvironment, account: Address?, exactApprovals: Bool = true) async {
        guard amountIn > 0, tokenIn != tokenOut else {
            result = nil
            resultKey = nil
            error = nil
            curve = nil
            // A fetch cancelled mid-flight (the amount cleared, or Done after a swap) returns without resetting it.
            quoting = false
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }
        while !Task.isCancelled {
            quoting = true
            let key = quoteKey
            let request = SwapRequest(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, slippageBps: slippageBps, account: Self.quoteAccount(account),
                                      exactApprovals: exactApprovals)
            let refreshing = resultKey == key && result?.isFinal == true
            var last: QuoteResult?
            for await update in env.swap.quoteUpdates(for: request) {
                last = update
                // Only a first round shows its answers as they arrive; the final one is shown below, after the stream.
                if update.isFinal || refreshing || Task.isCancelled { continue }
                result = update
                resultKey = key
                error = nil
                selection = selection.following(update)
            }
            if Task.isCancelled { return }
            // The stream ends with the final answer unless its task was cancelled, handled above.
            guard let outcome = last, outcome.isFinal else { quoting = false; return }
            result = outcome
            resultKey = key
            error = outcome.quotes.isEmpty ? (outcome.errors.values.first ?? tr("No venue can route this pair right now.")) : nil
            selection = selection.following(outcome)
            quoting = false
            if outcome.quotes.isEmpty {
                // No venue routes the pair, and that answer is already on screen. A side still on a launchpad's curve,
                // which no venue routes, trades on its Launch page instead (`curveSection`), so the state isn't a dead
                // end. Checked only now, after the answer shows, so a slow check (it has no venue timeout) never holds
                // it back; kept only while it still answers what is on screen, as `recheckCurve` does.
                let onCurve = await env.launchpad.curveRoute(among: [request.tokenOut, request.tokenIn])
                if Task.isCancelled { return }
                if key == quoteKey, resultKey == key { curve = onCurve; curveKey = key }
            } else {
                curve = nil
                curveKey = key
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }

}

/// Explains slippage in plain language, then lets the person pick a tolerance — presets with a one-line hint each,
/// or a custom percentage. The old control was a bare menu of numbers with no explanation.
struct SlippageSheet: View {
    @Binding var slippageBps: Int
    @Environment(\.dismiss) private var dismiss
    @State private var customText = ""
    private let presets = [10, 50, 100, 300]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Paragraph("How far the price may move before your swap settles. Beyond this, it cancels instead of filling worse.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } footer: {
                    LearnMoreLink(.slippageAndPriceImpact)
                }
                Section("Tolerance") {
                    ForEach(presets, id: \.self) { bps in
                        Button {
                            Haptics.selection(); slippageBps = bps; customText = ""
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(NumberStyle.basisPoints(bps)).foregroundStyle(.primary)
                                    Paragraph(hint(bps)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if slippageBps == bps { Image(systemName: "checkmark").foregroundStyle(Color.brand).fontWeight(.semibold) }
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Text("Custom")
                        Spacer()
                        TextField("0.5" as String, text: $customText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(maxWidth: 80)
                            .onChange(of: customText) { _, value in
                                if let pct = Double(value), pct > 0, pct <= 50 { slippageBps = Int((pct * 100).rounded()) }
                            }
                        Text(verbatim: "%").foregroundStyle(.secondary)
                    }
                } footer: {
                    if slippageBps >= 500 {
                        Label("A high tolerance can fill at a much worse price. Use it only for volatile or thin pairs.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Color.attention)
                    } else if slippageBps <= 10 {
                        Paragraph("A tight tolerance protects your price, but a swap can fail in a fast-moving market.").font(.caption)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Slippage"))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func hint(_ bps: Int) -> String {
        switch bps {
        case ...10: tr("Tightest price. Best for stable pairs.")
        case 11...50: tr("Balanced — recommended for most swaps.")
        case 51...100: tr("More forgiving when the market is moving.")
        default: tr("For volatile or low-liquidity pairs.")
        }
    }
}

/// One row in the swap-history list: a "sold → bought" line and when, linking to the transaction.
struct SwapHistoryItem: Identifiable, Hashable {
    let id: String
    let hash: Data?
    let time: Date
    let text: String

    /// A "sold → bought" line from a reconstructed swap, resolving symbols/decimals from the wallet's token set. When
    /// the token isn't known (so its decimals are unknown), the amount is omitted rather than shown with a guessed
    /// 18-decimal scale that could be wildly off — only the short address is shown.
    static func describe(_ swap: SwapRecord, tokens: [Address: Token]) -> String {
        func leg(_ address: Address, _ raw: BigUInt) -> String {
            guard let token = tokens[address] else { return address.short }
            return "\(NumberStyle.units(raw, decimals: token.decimals, compact: true)) \(token.symbol)"
        }
        // MON a sale paid out that couldn't be read (`SwapRecord.boughtNativeUnknown`) is named without an amount, never "0 MON".
        let bought = swap.boughtNativeUnknown ? (tokens[swap.boughtToken]?.symbol ?? Token.mon.symbol) : leg(swap.boughtToken, swap.boughtAmount)
        return "\(leg(swap.soldToken, swap.soldAmount)) → \(bought)"
    }
}

private struct SwapHistoryRow: View {
    let item: SwapHistoryItem

    var body: some View {
        Group {
            if let hash = item.hash {
                Link(destination: Monad.explorerTransaction(hash)) { content }.foregroundStyle(.primary)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.footnote.weight(.bold))
                .frame(width: 34, height: 34)
                .background(Color.brand.opacity(0.14), in: Circle())
                .foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(.subheadline.weight(.medium)).monospacedDigit()
                Text("\(RelativeTime.short(Int(item.time.timeIntervalSince1970))) ago").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if item.hash != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }
}

/// Searchable token list. Any Monad token can be added by pasting its address.
struct TokenPickerSheet: View {
    let selected: Token
    let balances: [Address: BigUInt]
    var universe: [Token] = Token.core
    /// Choosing a swap side (the default): a retired cohort's Moment coin is never offered. Home's search passes false —
    /// it only opens a token's page, which shows such a coin as "Past cohort · trading closed" with no swap.
    var tradableOnly = true
    /// Tokens found in the wallet rather than chosen (`KnownTokenStore.unverified`): left out of the list, and shown —
    /// marked — only when a search matches them (security audit 2026-09-26, IOST-12): a DyorHQ coin with its DyorHQ label
    /// in a section of its own, every other one as Unverified (`TokenPickerList`).
    var unverified: Set<Address> = []
    let onPick: (Token) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var custom: Token?
    @State private var lookingUp = false
    @State private var remoteResults: [Token] = []

    /// The main list (`TokenPickerList.main`): never a received token, a DyorHQ coin included; a retired cohort's Moment
    /// coin is never offered as a swap side, trading it being closed in the app. Assets the wallet holds float to the
    /// top, keeping the curated order within each group.
    private var tokens: [Token] {
        TokenPickerList.main(universe, unverified: unverified, balances: balances, query: query, tradableOnly: tradableOnly)
    }

    /// Received tokens in the wallet that match the search, each kind in its own section: the DyorHQ coins showing their
    /// DyorHQ label, and every other one, Unverified.
    private var receivedMatches: (dyorHQ: [Token], unverified: [Token]) {
        TokenPickerList.received(universe, unverified: unverified, query: query, excluding: custom?.address, tradableOnly: tradableOnly) {
            env.dyorCoins.badge($0, receivedUnasked: true).isDyorHQ
        }
    }

    /// Whether a search may miss a token because the venue list is still being read (`VenueTokenList.isCatchingUp`).
    /// Said only while searching by name: the default list is popular-only and never waits for it, and a pasted address
    /// is looked up on its own.
    private var venueListCatchingUp: Bool { !query.isEmpty && Address(query) == nil && env.venueList.isCatchingUp }

    /// Search hits for tokens not in the popular default list: the Uniswap/Monday venue list (accurate symbols +
    /// logos, matched locally, in memory) plus Kuru's directory. Only while searching — the default list stays
    /// popular-only. Computed once a render (`body`).
    private var remoteMatches: [Token] {
        guard !query.isEmpty else { return [] }
        var seen = Set(tokens.map(\.address)).union(universe.filter { unverified.contains($0.address) }.map(\.address))
        if let custom { seen.insert(custom.address) }
        let venueHits = env.venueList.tokens.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        var out: [Token] = []
        for token in venueHits + remoteResults where (!tradableOnly || SwapEngine.isTradable(token)) && seen.insert(token.address).inserted { out.append(token) }
        return out
    }

    var body: some View {
        let remote = remoteMatches
        let received = receivedMatches
        let noMatch = tokens.isEmpty && custom == nil && remote.isEmpty && received.dyorHQ.isEmpty && received.unverified.isEmpty
        NavigationStack {
            List {
                if let custom {
                    Section("By address") {
                        if tradableOnly, !SwapEngine.isTradable(custom) { closedRow(custom) } else { row(custom) }
                    }
                }
                Section {
                    ForEach(tokens) { row($0) }
                } footer: {
                    if noMatch {
                        if lookingUp {
                            Text("Looking up this token…")
                        } else if venueListCatchingUp {
                            Paragraph("No token matches yet: Monad's token list is still loading. Paste a contract address to add any Monad token.")
                        } else {
                            Paragraph("No token matches. Paste a contract address to add any Monad token.")
                        }
                    }
                }
                if !received.dyorHQ.isEmpty {
                    Section {
                        ForEach(received.dyorHQ) { row($0) }
                    } header: {
                        Text("DyorHQ coins in your wallet")
                    } footer: {
                        Paragraph("These were launched or published on DyorHQ and sent to your wallet without you choosing them here. Anyone can launch a coin on DyorHQ: check the contract before you trade.")
                    }
                }
                if !received.unverified.isEmpty {
                    Section {
                        ForEach(received.unverified) { row($0) }
                    } header: {
                        Text("Unverified — in your wallet")
                    } footer: {
                        Paragraph("These arrived in your wallet without you choosing them here. Anyone can send any token, with any name — including a real token's. Check the contract before you trade.")
                    }
                }
                // With nothing matched, the "no match" footer says the list is loading: never a second footer under it.
                if !remote.isEmpty || (venueListCatchingUp && !noMatch) {
                    Section {
                        ForEach(remote) { row($0) }
                    } header: {
                        if !remote.isEmpty { Text("More Monad tokens") }
                    } footer: {
                        if venueListCatchingUp { Paragraph("Monad's token list is still loading, so a token may be missing for now.") }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: tr("Symbol, name or address"))
            .navigationTitle(tr("Choose a Token"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: query) {
                custom = nil
                guard let address = Address(query), Token.core(address) == nil else { return }
                lookingUp = true
                custom = try? await ERC20.metadata(address, multicall: env.multicall)
                lookingUp = false
            }
            .task(id: query) {
                // Search the broad Kuru token directory, debounced. Empty/short queries clear it.
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { remoteResults = []; return }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                remoteResults = await env.kuruTokens.search(q)
            }
        }
    }

    /// A pasted past-cohort Moment coin: named so the address is not a dead end, never pickable.
    private func closedRow(_ token: Token) -> some View {
        HStack(spacing: 12) {
            TokenLogo(token: token, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(token.symbol).font(.headline)
                Text("Past cohort · trading closed").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func row(_ token: Token) -> some View {
        Button {
            Haptics.selection()
            onPick(token)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                TokenLogo(token: token, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(token.symbol).font(.headline)
                        TokenBadgeView(token: token, receivedUnasked: unverified.contains(token.address))
                    }
                    // Only Home's search lists a retired coin; its page has no swap either.
                    (SwapEngine.isTradable(token) ? Text(verbatim: token.displayName) : Text("Past cohort · trading closed")).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if let balance = balances[token.address], balance > 0 {
                    Text(NumberStyle.units(balance, decimals: token.decimals, compact: true)).monospacedDigit().foregroundStyle(.secondary)
                }
                if token == selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .foregroundStyle(.primary)
    }
}
