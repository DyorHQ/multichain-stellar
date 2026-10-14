import BigInt
import DyorKit
import Foundation
import Observation

/// Drives the cross-chain Bridge: the same DyorHQ wallet address moves funds between an EVM source chain and Monad
/// (either direction) via Aurora Intents. The app quotes, signs the deposit on the source chain itself, tells Aurora,
/// then polls until the funds land. Exactly one side is always Monad.
@Observable
@MainActor
final class BridgeModel {
    private let env: AppEnvironment

    private(set) var tokens: [AuroraToken] = []
    private(set) var loadingTokens = false
    private(set) var loadError: String?

    var fromChain: EVMChain
    var toChain: EVMChain
    var fromToken: AuroraToken?
    var toToken: AuroraToken?
    var amountText = ""

    /// Wallet balances keyed by Aurora `assetId` (globally unique across chains), covering every supported source
    /// chain — so the source picker can rank assets by what the user actually holds, on any chain.
    private(set) var balances: [String: BigUInt] = [:]
    private(set) var loadingBalances = false
    /// The chains whose balances were read in full for `balancesOwner` (Aurora ids), read again only with `force`. A chain
    /// read in part — an endpoint that failed, or answered after `MultiChainBalances.cap` (a cold connection to a
    /// third-party public RPC over cellular) — is not among them, and is read again (`loadBalances`).
    private var chainsRead: Set<String> = []
    /// The wallet `balances` and `chainsRead` are for.
    private var balancesOwner: Address?
    /// The chains being read now (Aurora ids): the send card waits on the source chain's (`readingFromBalance`).
    private var readingChains: Set<String> = []
    /// A forced load (a bridge landed) was asked while another load was under way: it runs once that one ends.
    private var forceAfterLoad = false
    /// The source chain's balances are being read: its balance line waits for them, while other chains' reads leave it as
    /// it is.
    var readingFromBalance: Bool { readingChains.contains(fromChain.auroraId) }

    private(set) var quote: AuroraQuote?
    /// The most the deposit's network fee can come to on the source chain at today's fees, once the quote names the
    /// deposit address (IOST-1). The deposit is signed there against a public RPC, within `NetworkFeeLimits`.
    private(set) var networkFee: TransactionSender.FeePreview?
    private(set) var quoting = false
    private(set) var quoteError: String?
    private var quoteTask: Task<Void, Never>?

    enum Phase: Equatable { case idle, signing, submitting, bridging(AuroraSwapStatus), done(String), settling(String), failed(String) }
    /// Signing and submitting, and failures before a deposit was sent. Once one is sent, `phase` follows the app-wide
    /// `BridgeTracker`, which keeps tracking it after this screen closes or the app is killed (GL-5).
    private var localPhase: Phase = .idle
    /// The deposit this screen sent and shows (its source transaction hash).
    private var trackedHash: String?
    var phase: Phase {
        guard let trackedHash, let status = env.bridgeTracker.status[trackedHash] else { return localPhase }
        switch status {
        case .bridging(let stage): return .bridging(stage)
        case .arrived(let out): return .done(out)
        case .unverified(let message), .settling(let message): return .settling(message)
        case .refunded(let message), .failed(let message): return .failed(message)
        }
    }
    /// The source deposit's explorer link, as soon as it's signed.
    private var sourceTxURL: URL?
    /// The block-explorer URL the "View" link opens: the source deposit tx as soon as it's signed, upgraded to the
    /// destination arrival tx once Aurora reports it, so the user can verify it on-chain.
    var completedTxURL: URL? { trackedHash.flatMap { env.bridgeTracker.arrivalURL[$0] } ?? sourceTxURL }

    init(env: AppEnvironment) {
        self.env = env
        // Default: bring funds in from a common L2 into Monad. Both sides are the same 0x address.
        fromChain = EVMChain.byAuroraId("base") ?? EVMChain.supported[0]
        toChain = env.bridgeMonad
    }

    var isConfigured: Bool { env.aurora.isConfigured }
    var monad: EVMChain { env.bridgeMonad }
    /// The chain the user chooses; the other side is pinned to Monad.
    var otherChain: EVMChain { fromChain.isMonad ? toChain : fromChain }
    var intoMonad: Bool { toChain.isMonad }
    /// EVM source chains other than Monad, in registry order.
    var selectableChains: [EVMChain] { EVMChain.supported.filter { !$0.isMonad } }

    func tokens(on chain: EVMChain) -> [AuroraToken] {
        tokens.filter { $0.blockchain == chain.auroraId }.sorted { stableRank($0) < stableRank($1) }
    }
    private func stableRank(_ t: AuroraToken) -> Int { ["USDC": 0, "USDT0": 1, "USDT": 2].first { $0.key == t.symbol }?.value ?? 3 }

    /// Every source-side asset (all supported chains except Monad), richest first: assets the user holds float to the
    /// top ordered by USD value, then the rest by a stable-first, alphabetical order. This is what the cross-chain
    /// source picker shows, so "100 USDT on Arbitrum" is the first thing the user sees.
    var sourceAssets: [AuroraToken] {
        tokens
            .filter { (EVMChain.byAuroraId($0.blockchain).map { !$0.isMonad }) ?? false }
            .sorted { a, b in
                let ha = held(a), hb = held(b)
                if ha != hb { return ha }                 // any holding ranks above no holding
                let va = balanceUSD(a), vb = balanceUSD(b)
                if va != vb { return va > vb }             // among holdings, richest by USD first
                let ra = stableRank(a), rb = stableRank(b)
                if ra != rb { return ra < rb }             // then the familiar stables
                if a.symbol != b.symbol { return a.symbol < b.symbol }
                return a.blockchain < b.blockchain
            }
    }

    // MARK: Loading

    /// The bridge's backend proxy serves a signed-in wallet only. RootView signs in as soon as the wallet can sign;
    /// this covers the moment right after launch before that sign-in has landed. Opening the screen is no tap for a
    /// signature, so it signs in only where that shows nothing (`Session.backgroundWallet`): a passkey account whose
    /// session is locked waits for `needsUnlock`'s button instead of a passkey prompt out of nowhere.
    private func ensureBackendSession() async {
        guard !env.social.isSignedIn, env.session.canSignWithoutPrompt,
              let address = env.session.address, let wallet = env.session.backgroundWallet else { return }
        await env.social.signIn(address: address, wallet: wallet)
    }

    /// A passkey account with no backend session and its passkey session locked: routes can't load until it unlocks.
    /// Once it does, RootView signs in to the backend and the view loads again.
    var needsUnlock: Bool { env.session.isPasskeyAccount && !env.session.canSignWithoutPrompt && !env.social.isSignedIn }

    /// Counts `load` calls: the view reloads when the account unlocks or its backend sign-in lands, and an earlier load
    /// may still be waiting on that sign-in (its task cancelled, which a joined sign-in doesn't notice). Only the newest
    /// writes, so a superseded one can't leave its "Cancelled." over a form that loaded.
    private var loadGeneration = 0

    func load() async {
        guard isConfigured else { loadError = AuroraError.notConfigured.errorDescription; return }
        guard tokens.isEmpty, !needsUnlock else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadingTokens = true
        defer { if generation == loadGeneration { loadingTokens = false } }
        loadError = nil
        await ensureBackendSession()
        do {
            let loaded = try await env.aurora.tokens().filter { EVMChain.byAuroraId($0.blockchain) != nil }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            tokens = loaded
            loadError = nil
            if fromToken == nil { fromToken = preferred(on: fromChain) }
            if toToken == nil { toToken = preferred(on: toChain) }
            await loadBalances()
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            loadError = describe(error)
        }
    }

    private func preferred(on chain: EVMChain) -> AuroraToken? {
        let list = tokens(on: chain)
        return list.first { $0.symbol == "USDC" } ?? list.first
    }

    // MARK: Selection

    /// Sets the non-Monad chain (Monad stays pinned to the other side) and resets its token + amount.
    func selectOtherChain(_ chain: EVMChain) {
        if intoMonad { fromChain = chain; fromToken = preferred(on: chain) }
        else { toChain = chain; toToken = preferred(on: chain) }
        resetQuote(); Task { await loadBalances() }
    }

    func flipDirection() {
        swap(&fromChain, &toChain)
        swap(&fromToken, &toToken)
        amountText = ""; resetQuote()
        Task { await loadBalances() }
    }

    func setFromToken(_ token: AuroraToken) { fromToken = token; resetQuote(); refreshQuoteSoon() }
    func setToToken(_ token: AuroraToken) { toToken = token; resetQuote(); refreshQuoteSoon() }

    /// Pick a source asset from the cross-chain list: this also switches the source chain to wherever the asset lives
    /// (choosing "USDT on Arbitrum" makes Arbitrum the source), keeping Monad pinned as the destination.
    func selectSourceAsset(_ token: AuroraToken) {
        guard let chain = EVMChain.byAuroraId(token.blockchain), !chain.isMonad else { return }
        fromChain = chain
        fromToken = token
        toChain = monad
        if toToken == nil || toToken?.blockchain != monad.auroraId { toToken = preferred(on: monad) }
        resetQuote(); refreshQuoteSoon()
    }

    // MARK: Balances

    /// Reads the wallet's balances across every supported chain at once (each chain independently, failures swallowed),
    /// so the source picker can rank by holdings. A chain read in full is not read again; pass `force` after a bridge
    /// lands to pick up the change. A chain read in part (`MultiChainBalances.ChainBalances.complete`) is read again at
    /// once, and on every load after until it is read in full (opening a picker, switching chains): it was latched as
    /// read, and its holdings showed as not held and its Max stayed off until a bridge landed.
    func loadBalances(force: Bool = false) async {
        guard let owner = env.session.address else { return }
        // Coalesce overlapping loads (first `load()` + a picker `.task`, etc.); a forced one runs after.
        guard !loadingBalances else { if force { forceAfterLoad = true }; return }
        if balancesOwner != owner {
            // Another wallet's balances are never shown for this one.
            balances = [:]
            chainsRead = []
            balancesOwner = owner
        }
        // Use the app's configured Monad endpoint for the Monad side; public RPCs for the rest.
        let plan: [(EVMChain, [AuroraToken])] = EVMChain.supported
            .map { $0.isMonad ? env.bridgeMonad : $0 }
            .compactMap { chain in
                let toks = tokens(on: chain)
                return toks.isEmpty || (!force && chainsRead.contains(chain.auroraId)) ? nil : (chain, toks)
            }
        guard !plan.isEmpty else { return }
        loadingBalances = true
        await readBalances(plan, owner: owner, force: force)
        loadingBalances = false
        readingChains = []
        if forceAfterLoad {
            forceAfterLoad = false
            await loadBalances(force: true)
        }
    }

    /// Reads `plan`'s chains for `owner` (`loadBalances`), each chain's balances shown as soon as it answers, those read in
    /// part once more at once.
    private func readBalances(_ plan: [(EVMChain, [AuroraToken])], owner: Address, force: Bool) async {
        var plan = plan
        let balancer = env.chainBalances
        // Each chain once, and those read in part once more at once: the connection the first read opened is usually up.
        for _ in 0 ..< 2 where !plan.isEmpty {
            readingChains = Set(plan.map(\.0.auroraId))
            var inPart: [(EVMChain, [AuroraToken])] = []
            await withTaskGroup(of: (chain: EVMChain, tokens: [AuroraToken], read: MultiChainBalances.ChainBalances).self) { group in
                for (chain, toks) in plan {
                    group.addTask { (chain, toks, await balancer.read(owner: owner, chain: chain, tokens: toks)) }
                }
                for await (chain, toks, read) in group {
                    // Never another wallet's balances (the account changed while they were read).
                    guard env.session.address == owner else { continue }
                    // What this read found replaces what was shown. A balance it couldn't read keeps the last one read this
                    // session, except after a bridge landed (`force`), which the old balance no longer shows.
                    for token in toks {
                        if let value = read.balances[token.assetId] { balances[token.assetId] = value } else if force { balances[token.assetId] = nil }
                    }
                    if read.complete {
                        chainsRead.insert(chain.auroraId)
                        readingChains.remove(chain.auroraId)
                    } else {
                        chainsRead.remove(chain.auroraId)
                        inPart.append((chain, toks))
                    }
                }
            }
            guard env.session.address == owner else { return }
            plan = inPart
        }
    }

    // Per-asset balance access for the pickers (keyed by the globally-unique assetId).
    func held(_ token: AuroraToken) -> Bool { (balances[token.assetId] ?? 0) > 0 }
    func balanceRaw(_ token: AuroraToken) -> BigUInt? { balances[token.assetId] }
    /// The USD value of the held balance (0 when nothing held or no price), used only to rank the picker.
    func balanceUSD(_ token: AuroraToken) -> Double {
        guard let raw = balances[token.assetId], raw > 0, let price = token.price, price > 0 else { return 0 }
        let units = (Double(raw.description) ?? 0) / pow(10, Double(token.decimals))
        return units * price
    }
    /// A compact "0.097 USDC" for a picker row; nil when the wallet holds none of it.
    func balanceText(_ token: AuroraToken) -> String? {
        guard let raw = balances[token.assetId], raw > 0 else { return nil }
        return "\(NumberStyle.units(raw, decimals: token.decimals, compact: true)) \(token.symbol)"
    }

    var fromBalanceRaw: BigUInt? { fromToken.flatMap { balances[$0.assetId] } }
    var fromBalanceText: String? {
        guard let token = fromToken, let raw = fromBalanceRaw else { return nil }
        return "\(NumberStyle.units(raw, decimals: token.decimals, compact: true)) \(token.symbol)"
    }

    func useMax() { usePercent(1) }

    /// Fill the amount with a fraction of the from-chain balance. "Max" of a token is the EXACT balance, never above
    /// it nor silently under; a Max of the chain's native coin keeps its network fee back. A share below 100% is rounded
    /// down to six significant digits (`Amount.roundedDown`), so the field reads "0.559465" rather than 18 decimals.
    func usePercent(_ fraction: Double) {
        guard let token = fromToken, let raw = fromBalanceRaw, raw > 0 else { return }
        if fraction >= 1, token.isNative {
            Task { await useNativeMax(token, balance: raw) }
            return
        }
        let amount = fraction >= 1 ? raw : Amount.roundedDown(raw * BigUInt(Int((fraction * 10000).rounded())) / 10000, decimals: token.decimals)
        setAmount(amount, of: token)
    }

    /// Max of a native coin (MERA-PLAN §5): the balance less what the deposit transfer can be charged on the source
    /// chain — its gas estimate (to the quote's deposit address, or a stand-in until Aurora names one) × (2 × base fee
    /// + tip) with headroom, or the chain's fallback when its RPC can't answer. Zero when the fee takes it all.
    private func useNativeMax(_ token: AuroraToken, balance: BigUInt) async {
        let chain = fromChain
        let recipient = quote?.depositAddress.flatMap { Address($0) } ?? Self.feeProbeRecipient
        let amount = await env.sender(for: chain).maxValue(balance: balance, like: TransactionRequest(to: recipient, value: 1),
                                                           from: env.session.address, budget: NetworkFeeReserve.transferGasLimit)
        // The source, its balance or the form changed while the fee was read: that Max no longer applies.
        guard canEdit, fromChain == chain, fromToken?.assetId == token.assetId, fromBalanceRaw == balance else { return }
        // Rounded down: a sliver more stays back with the fee reserve, and the field stays readable.
        setAmount(Amount.roundedDown(amount, decimals: token.decimals), of: token)
    }

    /// An address with no code, to estimate a plain transfer before there is a deposit address.
    private static let feeProbeRecipient = Address(literal: "0x000000000000000000000000000000000000dEaD")

    private func setAmount(_ amount: BigUInt, of token: AuroraToken) {
        amountText = Amount.exact(amount, decimals: token.decimals)
        resetQuote()
        refreshQuoteSoon()
    }

    // MARK: Quote

    var amountRaw: BigUInt? {
        guard let token = fromToken, let raw = Amount.parse(amountText, decimals: token.decimals), raw > 0 else { return nil }
        return raw
    }

    /// The user's balance can't cover the amount they typed.
    var insufficient: Bool {
        guard let amount = amountRaw, let balance = fromBalanceRaw else { return false }
        return amount > balance
    }

    func amountChanged() { resetQuote(); refreshQuoteSoon() }

    private func refreshQuoteSoon() {
        quoteTask?.cancel()
        guard amountRaw != nil else { return }
        quoteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.getQuote()
        }
    }

    func getQuote() async {
        guard let from = fromToken, let to = toToken, let owner = env.session.address, let amount = amountRaw else { return }
        quoting = true; quoteError = nil
        await ensureBackendSession()
        do {
            quote = try await env.aurora.quote(
                amount: String(amount), originAsset: from.assetId, destinationAsset: to.assetId,
                recipient: owner.checksummed, refundTo: owner.checksummed, slippageBps: slippageBps)
        } catch {
            quote = nil
            quoteError = humanize(describe(error))
            quoting = false
            return
        }
        quoting = false
        await loadNetworkFee()
    }

    /// Prices the deposit the quote asks for on the source chain (`networkFee`), shown on the review card beside the
    /// bridge's own fee.
    private func loadNetworkFee() async {
        networkFee = nil
        guard let quote, let deposit = quote.depositAddress.flatMap(Address.init), let from = fromToken, let owner = env.session.address,
              let amount = BigUInt(quote.amountIn), let request = try? Self.depositRequest(from, to: deposit, amount: amount) else { return }
        let chain = fromChain
        // not localized: the step's label is never shown, as this only estimates its fee.
        let fee = await env.sender(for: chain).feePreview([.call(request, label: "Deposit")], from: owner)
        // A new quote or source meanwhile: this fee isn't for it.
        guard self.quote?.depositAddress == quote.depositAddress, fromChain == chain else { return }
        networkFee = fee
    }

    private func resetQuote() { quoteTask?.cancel(); quote = nil; quoteError = nil; networkFee = nil }

    /// Aurora returns some validation errors with raw smallest-unit amounts (e.g. "…try at least 150000"). Reformat
    /// any standalone large integer in an amount error into human units of the source token, so the user reads
    /// "0.15 USDC" instead of "150000".
    private func humanize(_ message: String) -> String {
        // not localized: Aurora's own English error text, whatever the app's language.
        guard let token = fromToken,
              message.lowercased().contains("at least") || message.lowercased().contains("too low"),
              let regex = try? NSRegularExpression(pattern: #"\b\d{4,}\b"#) else { return message }
        let ns = message as NSString
        var result = message
        for match in regex.matches(in: message, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let value = BigUInt(ns.substring(with: match.range)) else { continue }
            let human = "\(NumberStyle.units(value, decimals: token.decimals)) \(token.symbol)"
            result = (result as NSString).replacingCharacters(in: match.range, with: human)
        }
        return result
    }

    var expectedOut: String? {
        guard let out = quote?.amountOutFormatted, let to = toToken else { return nil }
        return "\(out) \(to.symbol)"
    }

    /// Max slippage the app requests on every quote (basis points), user-adjustable via the slippage sheet. 1% is a
    /// safe default for cross-chain settlement. Changing it re-quotes, so the minimum-received and fee update at once.
    var slippageBps = 100 {
        didSet { guard slippageBps != oldValue else { return }; resetQuote(); refreshQuoteSoon() }
    }
    var slippageText: String { NumberStyle.basisPoints(slippageBps) }

    /// Total cost of the bridge (USD): input value minus output value — covers Aurora's protocol + withdraw fee, the
    /// route spread and the integrator fee, i.e. the one number a user needs to trust the flow.
    var feeText: String? {
        guard let q = quote, let inUsd = q.amountInUsd.flatMap(Double.init), let outUsd = q.amountOutUsd.flatMap(Double.init), inUsd > 0 else { return nil }
        let fee = max(0, inUsd - outUsd)
        let pct = fee / inUsd * 100
        let amount = PriceFormat.usdValue(fee, fractionDigits: fee < 0.01 ? 2...6 : 2...2)
        return "\(amount) · \(NumberStyle.number(pct, maximumFractionDigits: 2))%"
    }

    /// The guaranteed minimum the user receives after slippage (from the quote's `minAmountOut`).
    var minReceivedText: String? {
        guard let min = quote?.minAmountOut, let raw = BigUInt(min), let to = toToken else { return nil }
        return "\(NumberStyle.units(raw, decimals: to.decimals)) \(to.symbol)"
    }

    // MARK: Execute

    var isBusy: Bool {
        switch phase {
        case .signing, .submitting, .bridging: return true
        case .idle, .done, .settling, .failed: return false
        }
    }
    /// Only offer to bridge from a clean `.idle` state — once a deposit has been signed (`.done`/`.failed` from the
    /// poll path, `.signing`/`.submitting`/`.bridging` in flight) the primary button becomes "start over" (which
    /// resets and re-quotes), so the same real deposit can never be signed and sent twice.
    var canBridge: Bool {
        guard case .idle = phase else { return false }
        return fromToken != nil && toToken != nil && amountRaw != nil && !insufficient && quote?.depositAddress != nil
    }
    /// The form (chain/token/amount) is only editable from a clean `.idle` state. Once a deposit is signed — through the
    /// in-flight phases and the terminal `.done`/`.settling`/`.failed` (where a background poll may still be running) —
    /// the user must tap the primary to `reset()` first, so nothing can change the route while a bridge is settling.
    var canEdit: Bool { if case .idle = phase { return true }; return false }

    func execute() async {
        // A passkey account's bridge always asks (MERA-PLAN §3): one Face ID when the deposit is signed.
        guard let wallet = env.session.wallet(for: MeraSession.Action(.alwaysAsks(.bridge))) else { localPhase = .failed(tr("Sign in to bridge.")); return }
        guard let from = fromToken, let amount = amountRaw, let quote, let deposit = quote.depositAddress, let depositAddr = Address(deposit) else {
            localPhase = .failed(tr("Get a quote first.")); return
        }
        if env.settings.appLockApplies(to: env.session.account), !(await BiometricGate.authenticate(reason: tr("Confirm bridge"))) { return }
        localPhase = .signing
        trackedHash = nil
        sourceTxURL = nil
        // The quote is EXACT_INPUT for the amount the user typed, delivered back to the user's own address. Refuse to
        // sign anything else — a quote whose input amount, recipient or refund address differs from the request. This
        // catches a buggy or mismatched quote; it cannot prove the deposit address is Aurora's, because the request
        // echo arrives in the same response as that address: the address is trusted to Aurora and the aurora-proxy
        // Edge Function, and the review card shows it before the user confirms (security audit 2026-09-26, IOST-3).
        guard let quotedIn = BigUInt(quote.amountIn), quotedIn == amount else {
            localPhase = .failed(tr("The bridge quote didn't match the amount you entered, so nothing was sent. Get a new quote."))
            return
        }
        guard let owner = env.session.address, let to = toToken,
              quote.request?.matches(amount: amount, originAsset: from.assetId, destinationAsset: to.assetId, owner: owner) == true else {
            localPhase = .failed(tr("The bridge quote didn't match your request (amount, tokens or your address), so nothing was sent. Get a new quote."))
            return
        }
        let sendAmount = quotedIn
        let sourceChain = fromChain
        let destChain = toChain
        // A lock or an app switch while the deposit is signed and sent suspends this: ask for the time iOS grants, so the
        // deposit is broadcast, recorded and persisted, and Aurora told (GL-5).
        let background = BackgroundTime("Bridge") // not localized: the background task's name, never shown
        defer { background.end() }
        do {
            guard let request = try Self.depositRequest(from, to: depositAddr, amount: sendAmount) else {
                localPhase = .failed(tr("This source token can't be bridged.")); return
            }

            // The destination balance, asked for before signing (RI-3): the baseline an arrival is measured from. Asked
            // before the deposit exists, it can't include this bridge's credit, which takes the deposit confirming and the
            // bridge settling. Never the picker's cached balance, which can be missing or from before an earlier bridge
            // landed; a read that fails leaves no baseline, and the arrival is then never inferred from the balance. It
            // is recorded when it answers, after the deposit is persisted: a slow destination RPC never holds that up.
            // Another bridge to the same asset unsettled now rules the balance out for both (`PendingBridge.overlapped`).
            let balancer = env.chainBalances
            let baselineRead = Task { await balancer.balances(owner: owner, chain: destChain, tokens: [to])[to.assetId] }
            let overlapping = BridgeTracker.pending(owner: owner).contains { $0.destToken.assetId == to.assetId }
            let hash: Data
            do {
                hash = try await env.sender(for: sourceChain).send(request, from: wallet)
            } catch TransactionError.possiblySent(let possible) {
                // No endpoint said it took the deposit, but it may be live: track it rather than invite a second one.
                hash = possible
            } catch {
                baselineRead.cancel()
                throw error
            }
            trackedHash = hash.hexString
            sourceTxURL = sourceChain.explorerTx(hash.hexString) // source deposit tx — a verifiable link straight away
            // Recorded and persisted the moment it is sent, before anything else can go wrong (GL-5): the funds have left
            // the source chain.
            let bridgeFeeUsd: Double? = {
                guard let inUsd = quote.amountInUsd.flatMap(Double.init), let outUsd = quote.amountOutUsd.flatMap(Double.init) else { return nil }
                return max(0, inUsd - outUsd)
            }()
            let usd = quote.amountOutUsd.flatMap(Double.init) ?? quote.amountInUsd.flatMap(Double.init)
            ActivityLog.record(ActivityRecord(
                kind: .bridge, title: tr("Bridge \(from.symbol) → \(to.symbol)"),
                subtitle: "\(amountText) \(from.symbol) · \(sourceChain.name) → \(destChain.name)",
                hash: hash, section: "bridge", usd: usd, feeUsd: bridgeFeeUsd), owner: owner)
            let tracker = env.bridgeTracker
            tracker.track(PendingBridge(
                hash: hash.hexString, owner: owner, depositAddress: deposit, memo: quote.depositMemo,
                fromChainId: sourceChain.auroraId, toChainId: destChain.auroraId, fromName: sourceChain.name, toName: destChain.name,
                inSymbol: from.symbol, amountText: amountText, destToken: to, baseline: nil,
                minOut: quote.minAmountOut.flatMap { BigUInt($0) }, usd: usd, sentAt: Date(), overlapped: overlapping))
            Task {
                let baseline = await baselineRead.value
                tracker.setBaseline(baseline, for: hash.hexString, owner: owner)
            }
            localPhase = .submitting
            _ = try? await env.aurora.submitDeposit(txHash: hash.hexString, depositAddress: deposit, memo: quote.depositMemo)
            // The deposit address is consumed: `reset` re-quotes before another bridge can be sent (`canBridge`).
            localPhase = .bridging(.pendingDeposit)
        } catch where env.session.isPasskeyAccount && isUserCancellation(error) {
            localPhase = .failed(TransactionRun.notSent)
        } catch {
            localPhase = .failed(describe(error))
        }
    }

    /// The source-chain deposit: `amount` of `token` to Aurora's deposit address — a plain transfer of the native coin,
    /// or the token's `transfer`. Nil for a token with neither.
    private static func depositRequest(_ token: AuroraToken, to deposit: Address, amount: BigUInt) throws -> TransactionRequest? {
        if token.isNative { return TransactionRequest(to: deposit, value: amount) }
        guard let contract = token.contractAddress.flatMap(Address.init) else { return nil }
        return TransactionRequest(to: contract, data: try ERC20.transferCalldata(to: deposit, amount: amount))
    }

    /// Return to a clean state to start another bridge, keeping the entered amount and re-quoting it (so a
    /// pre-broadcast failure like "no gas" can be retried without retyping). A deposit already sent stays tracked by
    /// `BridgeTracker`; balances are read again, since it may have moved them.
    func reset() {
        trackedHash = nil
        sourceTxURL = nil
        localPhase = .idle
        resetQuote()
        if amountRaw != nil { refreshQuoteSoon() }
        Task { await loadBalances(force: true) }
    }
}

extension AuroraSwapStatus {
    /// A short user-facing label for the settlement stage.
    var label: String {
        switch self {
        case .pendingDeposit, .knownDepositTx: return tr("Confirming your deposit…")
        case .incompleteDeposit: return tr("Waiting for the full deposit…")
        case .processing: return tr("Bridging across chains…")
        case .success: return tr(LocalizedStringResource("Arrived", comment: "A bridge's status: the funds arrived [tight]"))
        case .refunded: return tr(LocalizedStringResource("Refunded", comment: "A bridge's status: the funds were returned [tight]"))
        case .failed: return tr(LocalizedStringResource("Failed", comment: "A bridge's status [tight]"))
        }
    }
}
