// Stellar copy of ios/DyorHQ/Swap/SwapView.swift SwapView (42cd8c7 sha256:621f0d426a56)
// Stellar copy of ios/DyorHQ/Swap/SwapView.swift SwapConfirmation (42cd8c7 sha256:8de476a28af6)
// The Swap side of Stellar's Earn tab (docs/DESIGN-stellar-parity.md §8.6.1, §8.6.2). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// Spot swaps on Stellar, laid out as Monad's Swap under the Earn tab's Swap | Earn switch: what you pay and receive,
/// the flip between them, the action, every venue's quote with the best preselected (the person can pick another), and
/// Swap History. It opens the pair a Swap entry asked for (`Router.openStellarSwap`): Home's search and add-funds card, a
/// token page, a graduated coin's Swap, the side menu's Spot. The review builds the venue on screen, and binds the
/// minimum the quotes footer shows.
struct StellarSwapView: View {
    @Environment(\.stellarSession) private var session
    @Environment(Router.self) private var router
    @State private var model = StellarSwapModel()
    @State private var picking: StellarSwapModel.Side?
    /// The quote under review, frozen when the sheet opens. Quotes refresh every 15 s, and the sheet builds its plan once,
    /// so reading the live quote would let the details drift from what's signed.
    @State private var reviewing: StellarSwapReview?
    @State private var showSlippage = false
    @State private var historyWindow: SwapHistoryService.Window = .day
    /// Counts the swaps settled here, so Swap History reads again after each.
    @State private var settledSwaps = 0

    private var store: LiteStore? { session?.store }

    /// How often Top Tokens' prices are read again while Swap is on screen: Home's cadence (§8.2.7).
    static let pricesInterval: Duration = .seconds(30)

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
            .navigationTitle(MenuItem.earnTitle)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { StellarTradeModeSwitcher() }
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
                StellarSearchSheet(purpose: side == .pay ? .pay : .receive) { id in
                    picking = nil
                    model.select(id, for: side)
                }
            }
            .sheet(item: $reviewing) { review in confirmation(review) }
            // Monad's sheet, within what a Stellar swap takes: a custom value outside it is capped, and the sheet says so.
            .sheet(isPresented: $showSlippage) { SlippageSheet(slippageBps: $model.slippageBps, range: StellarSwapModel.slippageRange) }
            .onChange(of: model.slippageBps) { _, _ in model.saveSlippage() }
            // The account's figures as Swap opens: its balances and XLM position, its holdings (a coin bought on a pool is
            // listed there, not in the account's balances), the fee estimates Max keeps back, and Top Tokens for the sides'
            // names, logos and prices, read again every 30 s while Swap is on screen (as Home polls) with the rows looked up
            // for sides Top Tokens doesn't list, so the dollar values follow the market.
            .task(id: store.map(ObjectIdentifier.init)) {
                guard let session, let store else { return }
                let reads = session.publicReads
                model.attach(store) { try await reads.market($0).row }
                model.markets = reads.markets
                async let account: Void = store.refreshAccount()
                async let holdings: Void = store.refreshHoldings()
                async let fees: Void = store.refreshFees()
                await reads.refreshMarkets()
                _ = await (account, holdings, fees)
                model.fillMaxIfRead()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: Self.pricesInterval) } catch { return }
                    await reads.refreshMarkets()
                    await model.refreshFound()
                }
            }
            .onChange(of: session?.publicReads.markets) { _, rows in model.markets = rows ?? [] }
            .onChange(of: store?.account) { _, _ in model.fillMaxIfRead() }
            .task(id: "\(model.sell)|\(model.buy)|\(model.account ?? "")") { await model.learnSides() }
            .task(id: model.quoteKey) { await model.quote() }
            .onChange(of: router.pendingStellar, initial: true) { _, pending in
                guard case .swap(let request) = pending else { return }
                router.pendingStellar = nil
                model.apply(request)
            }
        }
    }

    /// All the account's swaps over the selected range: DyorHQ's activity, each with what it really brought, newest first.
    /// A passkey account whose session ended signs in for it only when it taps to (decision 6).
    @ViewBuilder private var activitySection: some View {
        if session?.canSign == true {
            Section {
                Picker("Range", selection: $historyWindow) {
                    ForEach(SwapHistoryService.Window.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.historyStatus == .needsSignIn {
                    StellarSignInRow()
                } else if model.historyStatus == .failed, model.history.isEmpty {
                    InlineError(message: store?.lastError ?? tr("No connection. Check your network and try again."))
                } else if model.history.isEmpty, model.loadingHistory || model.historyStatus == .unread {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading swaps…").font(.subheadline).foregroundStyle(.secondary) }
                } else if model.history.isEmpty {
                    Text("No swaps in this range yet.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(model.history) { StellarSwapHistoryRow(item: $0) }
                }
            } header: {
                Text("Swap History")
            }
            // Again after each swap settles here, and once a passkey account's sign-in brings its session back.
            .task(id: "\(historyWindow.rawValue)-\(model.account ?? "")-\(settledSwaps)-\(session?.access == .session)") {
                await model.loadHistory(historyWindow)
            }
        }
    }

    private var paySection: some View {
        Section {
            tokenRow(side: .pay, token: model.tokenIn)
            AmountField(title: "0" as String, text: $model.amountText, token: nil) {
                Haptics.selection(); model.applyMax()
            }
            percentRow
        } header: {
            Text("You Pay")
        } footer: {
            HStack {
                if let balance = model.balance(model.sell) { payBalance(balance) }
                Spacer()
                if let usd = model.payUSD { Text(PriceFormat.usdValue(usd)) }
            }
            // With the header below trimmed to match (`receiveSection`), the flip button sits 10 pt from the balance
            // line and 10 pt from "You Receive".
            .padding(.bottom, -8)
        }
        .listSectionSpacing(0)
    }

    /// "Balance: 10,000 XLM", and for XLM what Stellar keeps locked in the account, which can't be swapped: " · 1.5 locked".
    @ViewBuilder private func payBalance(_ balance: Int64) -> some View {
        let token = model.tokenIn
        let line = tr("Balance: \(StellarFormat.units(balance, decimals: token.decimals)) \(token.code)")
        if model.isXLM(model.sell), let locked = model.lockedXLM, locked > 0 {
            let kept = liteTr(LocalizedStringResource("\(StellarFormat.units(locked)) locked", table: "StellarSwap", comment: "Swap on Stellar, after the XLM balance under 'You Pay': how much of it Stellar keeps in the account (its minimum balance), which can't be swapped. The value is an amount of XLM (1.5)"))
            Text(verbatim: "\(line) · \(kept)") // not localized: two lines of text joined
                .accessibilityLabel(Text("Balance \(StellarFormat.units(balance)) XLM, of which \(StellarFormat.units(locked)) XLM is locked as Stellar's minimum balance", tableName: "StellarSwap", comment: "VoiceOver: the XLM balance under Swap's 'You Pay' on Stellar. The values are amounts of XLM: the balance, then the part Stellar keeps in the account as its minimum balance. Stellar and XLM are never translated"))
        } else {
            Text(verbatim: line)
        }
    }

    /// Quick-size the pay amount to a share of what can be swapped — 25 / 50 / 75 / 100%: of the spendable XLM for XLM, of
    /// the balance otherwise. 100% is Max, which keeps XLM's network fee and minimum balance back.
    private var percentRow: some View {
        HStack(spacing: 8) {
            ForEach([25, 50, 75, 100], id: \.self) { pct in
                Button {
                    Haptics.selection()
                    model.applyPercent(pct)
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
        .disabled((model.balance(model.sell) ?? 0) == 0)
        .listRowSeparator(.hidden)
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

    /// The swap's action, in the page right under what it trades.
    private var actionSection: some View {
        Section {
            // Disabled while the amount can't be swapped: the title says why (UI-4).
            PrimaryButton(title: model.actionTitle, isBusy: false, isDisabled: model.review == nil) { reviewing = model.review }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private var receiveSection: some View {
        Section {
            tokenRow(side: .receive, token: model.tokenOut)
            HStack {
                if let route = model.shownRoute {
                    Text(verbatim: StellarFormat.amount(route.amountOut, code: model.tokenOut.code, decimals: model.tokenOut.decimals))
                        .font(.title2.weight(.medium))
                        .monospacedDigit()
                } else if model.awaitingQuote {
                    ProgressView().controlSize(.small)
                    Text("Finding the best price").foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "0").font(.title2.weight(.medium)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        } header: {
            Text("You Receive")
                .padding(.top, -10) // the same 10 pt from the flip button as the balance line above it (`paySection`)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let balance = model.balance(model.buy) {
                        Text("Balance: \(StellarFormat.units(balance, decimals: model.tokenOut.decimals)) \(model.tokenOut.code)")
                    }
                    Spacer()
                    if let usd = model.receiveUSD { Text(PriceFormat.usdValue(usd)) }
                }
                // Receiving an asset the account hasn't enabled adds its trustline to this review, which holds one base
                // reserve of the account's own XLM.
                if model.needsEnable, let reserve = model.baseReserve {
                    Paragraph(LocalizedStringResource("Enabling \(model.tokenOut.code) holds \(StellarFormat.units(reserve)) XLM. It's part of this review.", table: "StellarSwap", comment: "Swap on Stellar, under 'You Receive', when the account hasn't enabled the asset it buys (a Stellar trustline): enabling it is a step of the same review and keeps this much of the account's XLM. The values are the asset's code (USDC) and an amount of XLM (0.5). XLM is never translated"))
                }
            }
        }
    }

    /// Swap's "no venue" state when a side is a DyorHQ coin still on its launchpad: no venue routes a curve, so rather than
    /// a dead end it says where the coin trades and opens its Launch page.
    @ViewBuilder private var curveSection: some View {
        if model.amountIn > 0, let coin = model.curveToken {
            Section {
                Label {
                    Paragraph(LocalizedStringResource("This coin trades on its Launch page until it graduates.", table: "StellarSwap", comment: "Swap on Stellar, when one side is a DyorHQ coin still on its launchpad's curve: no venue can swap it yet, it trades on its Launch page"))
                } icon: {
                    Image(systemName: "arrow.up.right.circle")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Button("Open the Launch Page", systemImage: "arrow.up.right.circle") {
                    router.openStellar(.launch(token: coin.contract ?? coin.id))
                }
            }
        }
    }

    @ViewBuilder private var quotesSection: some View {
        if model.curveToken == nil, model.amountIn > 0, !model.routes.isEmpty {
            Section {
                ForEach(model.routes) { route in
                    Button { Haptics.selection(); model.pick(route.venue) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(verbatim: StellarSwapRoute.name(route.venue)).font(.headline)
                                    if route.best {
                                        Text("Best").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.positive.opacity(0.15), in: Capsule()).foregroundStyle(Color.positive)
                                    }
                                }
                                Text(verbatim: model.pathText(route)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(verbatim: StellarFormat.amount(route.amountOut, code: model.tokenOut.code, decimals: model.tokenOut.decimals))
                                    .font(.body.weight(.medium))
                                    .monospacedDigit()
                                if let impact = route.priceImpactBps {
                                    Text("Impact \(NumberStyle.basisPoints(abs(impact)))").font(.footnote).foregroundStyle(abs(impact) > 100 ? Color.attention : .secondary)
                                }
                            }
                            Image(systemName: model.shownRoute?.venue == route.venue ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.shownRoute?.venue == route.venue ? Color.accentColor : Color(.tertiaryLabel))
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                HStack {
                    Text("Quotes")
                    Spacer()
                    if model.quoting { ProgressView().controlSize(.mini) }
                }
            } footer: {
                if let route = model.shownRoute {
                    Paragraph("Minimum received \(StellarFormat.units(route.minimum, decimals: model.tokenOut.decimals)) \(model.tokenOut.code) at \(NumberStyle.basisPoints(model.currentResult?.slippageBps ?? model.slippageBps)) slippage. Quotes refresh every 15 seconds.")
                }
            }
        } else if model.curveToken == nil, let error = model.currentError {
            Section { InlineError(message: error) }.listRowBackground(Color.clear)
        } else if model.awaitingQuote, model.quoting {
            // Every venue is asked in one request: until it answers, the venues are being checked.
            Section {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking…").font(.footnote).foregroundStyle(.tertiary)
                    Spacer()
                }
            } header: {
                Text("Quotes")
            }
        }
    }

    private func tokenRow(side: StellarSwapModel.Side, token: StellarSwapToken) -> some View {
        Button { Haptics.selection(); picking = side } label: {
            HStack(spacing: 12) {
                StellarTokenLogo.init(symbol: token.code, classic: token.classic, image: token.image, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: token.code).font(.headline)
                        if let badge = StellarTokenBadge.kind(badges: token.badges, verified: token.verified, code: token.code) { StellarTokenBadge(badge) }
                    }
                    if let name = token.name { Text(verbatim: name).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(side == .pay ? Text("Pay with \(token.code)") : Text("Receive \(token.code)"))
        .accessibilityHint("Choose a different token")
    }

    private func confirmation(_ review: StellarSwapReview) -> some View {
        StellarSwapConfirmation(review: review, build: { try await model.plan(for: review) }, pathText: model.pathText(review.route),
                                onDone: { model.amountText = "" }, onCompleted: {
                                    // Swap History reads again, and a coin's price follows the pool the swap just moved. The
                                    // store reads the balances again itself (`LiteStore.run`).
                                    settledSwaps += 1
                                    Task {
                                        await session?.publicReads.refreshMarkets()
                                        await model.refreshFound()
                                    }
                                })
    }
}

extension StellarSwapReview {
    /// The two sides as Swap showed them, for the review's You pay and Minimum received rows (Monad's name both by symbol,
    /// as You receive does): a DyorHQ coin or an asset the registry doesn't list would otherwise read as its short contract.
    /// Keyed by each side's id and the contract the phone derives from it, as `LiteStore.swapPlan` binds them (a coin's
    /// id is its contract; a classic asset's "CODE:ISSUER" has its Stellar Asset Contract), never by a server's string.
    var named: [String: StellarBoundRows.Name] {
        var named: [String: StellarBoundRows.Name] = [:]
        for side in [sell, buy] {
            let name = StellarBoundRows.Name(code: side.code, decimals: side.decimals)
            named[side.id] = name
            if let contract = LiteStore.assetContract(side.id, network: LiteGate.pinned.network) { named[contract] = name }
        }
        return named
    }
}

/// Builds the plan for the reviewed quote through the venue it shows, then hands it to the Stellar review sheet, with
/// Monad's rows in Monad's order (§8.6.1): You pay, You receive, Minimum received, Venue, Route, Slippage. What the
/// account pays and the least it receives are the plan's own rows (`StellarConfirmationSheet`'s `receives`), checked
/// against the review before anything is signed; the network fee, any asset the swap enables, and DyorHQ paying a
/// starter swap's fee (only when the phone proved it) come from the plan too.
private struct StellarSwapConfirmation: View {
    let review: StellarSwapReview
    let build: () async throws -> PreparedAction
    /// The route's assets by code ("XLM → USDC").
    let pathText: String
    let onDone: () -> Void
    let onCompleted: () -> Void

    var body: some View {
        let route = review.route
        StellarConfirmationSheet(title: "Review Swap", confirmTitle: "Swap", build: build, onDone: onDone, onCompleted: { _ in onCompleted() },
                                 receives: StellarFormat.amount(route.amountOut, code: review.buy.code, decimals: review.buy.decimals),
                                 named: review.named) {
            DetailRow("Venue", verbatim: StellarSwapRoute.name(route.venue))
            DetailRow("Route", verbatim: pathText)
            DetailRow("Slippage", NumberStyle.basisPoints(review.slippageBps))
        }
    }
}
#endif
