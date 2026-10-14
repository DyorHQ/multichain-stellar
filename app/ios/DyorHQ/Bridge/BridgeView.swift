import DyorKit
import SwiftUI

/// Cross-chain Bridge (Home "Bridge"). Moves the user's own funds between their address on any EVM chain and Monad,
/// both directions, via Aurora Intents — the app quotes, signs the source-chain deposit, and tracks settlement. One
/// side is always Monad, so the chain picker only ever chooses the other chain.
struct BridgeView: View {
    @State private var model: BridgeModel
    @Environment(Session.self) private var session
    @Environment(SocialSession.self) private var social
    @State private var unlocking = false
    @State private var unlockError: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var amountFocused: Bool
    @State private var showChainPicker = false
    @State private var showSourcePicker = false
    @State private var pickingFromToken = false
    @State private var pickingToToken = false
    @State private var showSlippage = false

    init(env: AppEnvironment) { _model = State(initialValue: BridgeModel(env: env)) }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            Group {
                #if DEBUG && targetEnvironment(simulator)
                // Simulator test mode: the stub's key signs on the local Monad fork only, and a bridge signs on another
                // chain (`Mera.Stub.permits`), so the screen is closed rather than failing at the signature.
                if session.isStubAccount {
                    ContentUnavailableView(Mera.Stub.unavailableTitle, systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("This test passkey signs on the local Monad fork only. Bridging needs a real passkey on a device."))
                } else if !model.isConfigured {
                    ContentUnavailableView {
                        Label("Bridge unavailable", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Paragraph("Cross-chain bridging isn't configured in this build yet.")
                    }
                } else if model.needsUnlock {
                    unlockPrompt
                } else {
                    form
                }
                #else
                if !model.isConfigured {
                    ContentUnavailableView {
                        Label("Bridge unavailable", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Paragraph("Cross-chain bridging isn't configured in this build yet.")
                    }
                } else if model.needsUnlock {
                    unlockPrompt
                } else {
                    form
                }
                #endif
            }
            .navigationTitle(tr("Bridge"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("Close", comment: "Closes this screen or sheet (a verb)") } }
                ToolbarItem(placement: .keyboard) { HStack { Spacer(); Button("Done") { amountFocused = false } } }
            }
        }
        // Again once a locked passkey account unlocks (its load then joins RootView's backend sign-in) or signs in.
        .task(id: "\(session.mera.isUnlocked)-\(social.isSignedIn)") {
            #if DEBUG && targetEnvironment(simulator)
            if session.isStubAccount { return } // nothing to load for a closed screen (and no backend sign-in)
            #endif
            await model.load()
        }
        .sheet(isPresented: $showChainPicker) { chainPicker }
        .sheet(isPresented: $showSourcePicker) { sourceAssetPicker }
        .sheet(isPresented: $pickingFromToken) { tokenPicker(for: model.fromChain, isFrom: true) }
        .sheet(isPresented: $pickingToToken) { tokenPicker(for: model.toChain, isFrom: false) }
        .sheet(isPresented: $showSlippage) { SlippageSheet(slippageBps: $model.slippageBps) }
    }

    /// A locked passkey account: one tap opens its session (the passkey prompt the person asked for), then the routes load.
    private var unlockPrompt: some View {
        ContentUnavailableView {
            Label("Unlock to bridge", systemImage: "lock.fill")
        } description: {
            if let unlockError { Paragraph(verbatim: unlockError) } else { Paragraph("Bridge routes load once your passkey session is open.") }
        } actions: {
            Button {
                Haptics.tap()
                unlocking = true
                Task {
                    defer { unlocking = false }
                    do { try await session.mera.unlock(); unlockError = nil }
                    catch where isUserCancellation(error) { unlockError = nil }
                    catch { unlockError = describe(error) }
                }
            } label: {
                Label("Unlock with \(BiometricGate.promptName)", systemImage: BiometricGate.promptSymbol)
            }
            .buttonStyle(.borderedProminent)
            .disabled(unlocking)
        }
    }

    /// The source-token tap opens the cross-chain, balance-sorted asset picker (which also switches chains); only when
    /// the source itself is Monad — bridging out — does it fall back to the plain Monad token list.
    private func openFromTokenPicker() {
        if model.fromChain.isMonad { pickingFromToken = true } else { showSourcePicker = true }
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let error = model.loadError { InlineError(message: error) }

                ZStack {
                    VStack(spacing: 6) {
                        sendCard
                        receiveCard
                    }
                    flipButton
                }

                if let error = model.quoteError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Color.attention)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                slippageControl
                summaryCard
                statusCard

                if session.isPasskeyAccount, model.canEdit {
                    SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.bridge.summary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                PrimaryButton(title: primaryTitle, isBusy: model.isBusy, isDisabled: !primaryEnabled) {
                    amountFocused = false
                    Task { await runPrimary() }
                }
                .disabled(!primaryEnabled)
                .padding(.top, 2)

                VStack(spacing: 4) {
                    Paragraph("Powered by Aurora Intents · cross-chain settlement handled for you.")
                        .foregroundStyle(.secondary)
                    LearnMoreLink(.bridge)
                }
                .font(.caption2).frame(maxWidth: .infinity)
                .padding(.top, 2)
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Send / receive

    private var sendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("You send").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if model.readingFromBalance { ProgressView().controlSize(.mini) }
                else if let bal = model.fromBalanceText {
                    Button { model.useMax() } label: {
                        Text("Balance: \(bal)").font(.caption).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                selectorStack(chain: model.fromChain, token: model.fromToken) { openFromTokenPicker() }
                Spacer(minLength: 8)
                TextField("0" as String, text: Binding(get: { model.amountText }, set: { model.amountText = $0; model.amountChanged() }))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .focused($amountFocused)
                    .disabled(!model.canEdit)
                    .foregroundStyle(model.insufficient ? Color.negative : Color.primary)
            }
            HStack(spacing: 8) {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    Button { model.usePercent(fraction) } label: {
                        (fraction >= 1 ? Text("Max", comment: "The most allowed: a button or chip that fills in the whole balance, or the highest leverage or amount [tight]") : Text(verbatim: "\(Int(fraction * 100))%"))
                            .font(.caption.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.brand)
                    .disabled(model.fromBalanceRaw == nil || !model.canEdit)
                }
            }
            if model.insufficient {
                Text("More than your \(model.fromChain.name) balance.").font(.caption2).foregroundStyle(Color.negative)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var receiveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You receive on \(model.toChain.name)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                selectorStack(chain: model.toChain, token: model.toToken) { pickingToToken = true }
                Spacer(minLength: 8)
                if model.quoting { ProgressView().controlSize(.small) }
                else {
                    Text(verbatim: model.quote?.amountOutFormatted.map { "≈ \($0)" } ?? "—")
                        .font(.system(size: 26, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A chain chip beside a token chip — the source/destination identity for one side, each with its logo.
    private func selectorStack(chain: EVMChain, token: AuroraToken?, tokenAction: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button { if !chain.isMonad { showChainPicker = true } } label: {
                chainChip(chain)
            }
            .buttonStyle(.plain).disabled(chain.isMonad || !model.canEdit)
            Button(action: tokenAction) { tokenChip(token) }
                .buttonStyle(.plain).disabled(!model.canEdit)
        }
        .layoutPriority(1) // keep the pills at their intrinsic width; the amount field yields instead
    }

    private func chainChip(_ chain: EVMChain) -> some View {
        HStack(spacing: 6) {
            ChainBadge(chain: chain, size: 20)
            Text(chain.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            if !chain.isMonad { Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }

    private func tokenChip(_ token: AuroraToken?) -> some View {
        HStack(spacing: 6) {
            if let token { MarketLogo(symbol: token.symbol, url: token.logoURL, size: 20) }
            else { Image(systemName: "circle.dashed").font(.subheadline).foregroundStyle(.secondary).frame(width: 20, height: 20) }
            (token.map { Text(verbatim: $0.symbol) } ?? Text("Token"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }

    private var flipButton: some View {
        Button { withAnimation(.snappy) { model.flipDirection() } } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.bold)).foregroundStyle(Color.onStatus)
                .frame(width: 36, height: 36).background(Color.brand, in: Circle())
                .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 4))
        }
        .buttonStyle(.plain).disabled(!model.canEdit)
    }

    // MARK: Summary + status

    /// Always-visible max-slippage control; opens the shared slippage sheet, which re-quotes on change.
    private var slippageControl: some View {
        Button { showSlippage = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(Color.brand)
                Text("Max slippage").foregroundStyle(.secondary)
                Spacer()
                Text(model.slippageText).fontWeight(.semibold).monospacedDigit().foregroundStyle(.primary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!model.canEdit)
    }

    @ViewBuilder private var summaryCard: some View {
        if let quote = model.quote {
            VStack(spacing: 0) {
                summaryRow("You receive", model.expectedOut ?? "—", tint: .positive, bold: true)
                Divider()
                summaryRow("Minimum received", model.minReceivedText ?? "—")
                summaryRow("Total fee", model.feeText ?? "—")
                // The source chain's own network fee for the deposit, which the bridge's fee doesn't include (IOST-1).
                if let fee = model.networkFee { summaryRow("Max network fee", fee.summary) }
                summaryRow("Slippage", model.slippageText)
                if let secs = quote.timeEstimate, secs > 0 { summaryRow("Estimated time", "≈ \(RelativeTime.seconds(Int(secs)))") }
                summaryRow("Route", "\(model.fromChain.name) → \(model.toChain.name)")
                // Where the funds actually go on the source chain: Aurora's one-time deposit address for this quote.
                if let deposit = quote.depositAddress.flatMap(Address.init) { summaryRow("Deposit to", deposit.short) }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func summaryRow(_ label: LocalizedStringKey, _ value: String, tint: Color = .primary, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.weight(bold ? .semibold : .medium)).monospacedDigit().foregroundStyle(tint)
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder private var statusCard: some View {
        switch model.phase {
        case .idle: EmptyView()
        case .signing, .submitting, .bridging:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(progressText).font(.subheadline)
                Spacer()
                if let url = model.completedTxURL {
                    Link(destination: url) { Text("View", comment: "Opens the transaction in a block explorer: a verb [tight]") }.font(.subheadline.weight(.semibold))
                }
            }
            .padding(14).background(Color.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .done(let out):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Color.positive)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arrived on \(model.toChain.name)").font(.subheadline.weight(.semibold))
                    if !out.isEmpty { Text("Received \(out)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let url = model.completedTxURL {
                    Link(destination: url) { Text("View", comment: "Opens the transaction in a block explorer: a verb [tight]") }.font(.subheadline.weight(.semibold))
                }
            }
            .padding(14).background(Color.positive.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .settling(let message):
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(Color.attention)
                Paragraph(message).font(.caption)
                Spacer()
                if let url = model.completedTxURL {
                    Link(destination: url) { Text("View", comment: "Opens the transaction in a block explorer: a verb [tight]") }.font(.footnote.weight(.semibold))
                }
            }
            .padding(14).background(Color.attention.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .failed(let message):
            InlineError(message: message)
        }
    }

    private var progressText: String {
        switch model.phase {
        case .signing: return tr("Sending on \(model.fromChain.name)…")
        case .submitting: return tr("Notifying the bridge…")
        case .bridging(let s): return s.label
        default: return ""
        }
    }

    // MARK: Primary button

    private var primaryTitle: String {
        switch model.phase {
        case .done: return tr("Bridge again")
        case .settling: return tr("Done")
        case .failed: return tr("Try again")
        case .signing, .submitting, .bridging: return tr("Bridging…")
        default: return model.intoMonad ? tr("Bridge to Monad") : tr("Bridge to \(model.toChain.name)")
        }
    }

    /// After a deposit is signed (poll-path `.done`/`.settling`/`.failed`) the button is a "start over" that resets and
    /// re-quotes — never a second `execute()`, so a real deposit can't be double-sent.
    private var primaryEnabled: Bool {
        switch model.phase {
        case .idle: return model.canBridge
        case .done, .settling, .failed: return true
        default: return false
        }
    }

    private func runPrimary() async {
        switch model.phase {
        case .done, .settling, .failed: model.reset()
        default: await model.execute()
        }
    }

    // MARK: Pickers

    private var chainPicker: some View {
        NavigationStack {
            List(model.selectableChains) { chain in
                Button { model.selectOtherChain(chain); showChainPicker = false } label: {
                    HStack(spacing: 12) {
                        ChainBadge(chain: chain, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chain.name)
                            Text(chain.nativeSymbol).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if chain == model.otherChain { Image(systemName: "checkmark").foregroundStyle(Color.brand) }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(model.intoMonad ? tr("Bridge from") : tr("Bridge to"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    /// The source-asset picker: every asset across every supported chain, the wallet's holdings first (highest value
    /// on top), each with its logo, chain badge and balance. Tapping one sets both the token and its chain.
    private var sourceAssetPicker: some View {
        NavigationStack {
            List(model.sourceAssets) { token in
                let chain = EVMChain.byAuroraId(token.blockchain) ?? model.fromChain
                Button {
                    model.selectSourceAsset(token)
                    showSourcePicker = false
                } label: {
                    HStack(spacing: 12) {
                        AssetGlyph(token: token, chain: chain, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(token.symbol).fontWeight(.medium)
                            Text(chain.name).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let balance = model.balanceText(token) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(balance).font(.subheadline.weight(.medium)).monospacedDigit()
                                let usd = model.balanceUSD(token)
                                if usd > 0 {
                                    Text(PriceFormat.usdValue(usd)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        } else if token == model.fromToken {
                            Image(systemName: "checkmark").foregroundStyle(Color.brand)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay {
                if model.loadingBalances && model.sourceAssets.allSatisfy({ !model.held($0) }) {
                    ProgressView("Reading your balances…").font(.footnote)
                }
            }
            .navigationTitle(tr("Bridge from"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSourcePicker = false } } }
            .task { await model.loadBalances() } // ensure balances are read (retries if a first load failed)
        }
        .presentationDetents([.large])
    }

    private func tokenPicker(for chain: EVMChain, isFrom: Bool) -> some View {
        NavigationStack {
            List(model.tokens(on: chain)) { token in
                Button {
                    if isFrom { model.setFromToken(token) } else { model.setToToken(token) }
                    pickingFromToken = false; pickingToToken = false
                } label: {
                    HStack(spacing: 12) {
                        MarketLogo(symbol: token.symbol, url: token.logoURL, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(token.symbol).fontWeight(.medium)
                            Text(chain.name).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let balance = model.balanceText(token) {
                            Text(balance).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                        let selected = isFrom ? model.fromToken : model.toToken
                        if token == selected { Image(systemName: "checkmark").foregroundStyle(Color.brand) }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(tr("\(chain.name) token"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
