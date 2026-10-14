import BigInt
import Charts
import DyorKit
import SwiftUI

/// Perpetuals on Perpl, as a single-screen trading app: the Trade screen renders the ticket, live book, chart and
/// positions for the currently-selected market, and the market header's chevron swaps markets in place through a
/// Select Perpetual sheet — no drilling into a list. Account, positions, open orders and markets are all read from
/// the Exchange contract; deposit/withdraw and the portfolio live in the header's ⋯ menu.
struct PerpsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var model = PerpsModel()
    @State private var selectedId: Int?

    /// The market to trade: the explicit selection, else the deep-linked one, else BTC, else the first listed.
    private var currentMarket: PerpMarket? {
        if let selectedId, let m = model.markets.first(where: { $0.id == selectedId }) { return m }
        return model.markets.first { $0.asset == "BTC" } ?? model.markets.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let market = currentMarket {
                    PerpTradeView(market: market, model: model, onSelectMarket: { id in
                        withAnimation(.easeInOut(duration: 0.15)) { selectedId = id }
                    })
                    .id(market.id)   // reset the ticket/feed cleanly when the market changes
                } else if model.loading {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("No Markets", systemImage: "chart.bar.xaxis")
                    } description: {
                        Paragraph("Perpl's markets couldn't be loaded. DyorHQ keeps retrying every few seconds.")
                    } actions: {
                        Button("Try Again") { Haptics.tap(); Task { await model.load(env: env, address: session.address) } }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { TradeModeSwitcher() }
            .task(id: session.address) { await model.poll(env: env, address: session.address) }
            // An order's result just came in on the trading stream: the chain is read again now, not at the next poll.
            .onChange(of: env.perplTrading.streamRevision) { _, _ in Task { await model.reloadSoon(env: env, address: session.address) } }
            .onChange(of: router.pendingPerpMarket) { _, id in
                if let id { selectedId = id; router.pendingPerpMarket = nil }
            }
            // Fallback for when this view is created *after* the deep link is set — e.g. opening a perp from Home
            // while the Trade tab is in Swap mode, which builds PerpsView fresh with pendingPerpMarket already set,
            // so `.onChange` never fires.
            .onAppear {
                if let id = router.pendingPerpMarket { selectedId = id; router.pendingPerpMarket = nil }
            }
        }
    }
}

enum PerpsSheet: Identifiable { case deposit, withdraw; var id: Self { self } }

@Observable
@MainActor
final class PerpsModel {
    private(set) var markets: [PerpMarket] = []
    private(set) var context: [Int: MarketContext] = [:]
    private(set) var account: PerpAccount?
    private(set) var positions: [PerpPosition] = []
    /// When `positions` was last read from the chain: an order compares the position it finds afterwards with this one
    /// (`PerplPositionEvidence`), and only a recent read counts.
    private(set) var positionsReadAt: Date?
    private(set) var orders: [PerpOrder] = []
    /// App-placed TP/SL the user set, reconciled against open positions/orders each poll (Perpl has no read-back API).
    private(set) var triggers: [PlacedTrigger] = []
    private(set) var collateral: (wallet: BigUInt, allowance: BigUInt) = (0, 0)
    private(set) var loading = false
    private(set) var error: String?
    var closing: PerpPosition?
    var cancelling: PerpOrder?
    private var perpl: PerplService?

    /// Fill detection for this screen: increments whenever an open order fills (a position appears or grows between
    /// polls), with `lastFilledPerpId` naming the market so the trade screen can jump to Positions. Position size is in
    /// base contracts — it moves only on fills and closes, never with the mark — so a size increase is an unambiguous
    /// fill signal that never fires on a cancel or a price move. The fill and close NOTICES come from the app-wide
    /// watcher (`AlertCenter`), on any screen, so this screen never posts one of its own (one notice, not two).
    private(set) var fillSignal = 0
    private(set) var lastFilledPerpId: Int?
    /// The positions at the last good read (`PerpPositionWatch`): what opened, grew or ended since.
    private var watch = PerpPositionWatch()
    /// Whose positions `watch` describes; a different account starts over.
    private var diffOwner: Address?
    /// The app-wide watcher, told when the user closes a position from here.
    @ObservationIgnored private var alerts: AlertCenter?
    /// Loads overlap (the poll, a reload the stream asked for, a sheet's Done): each is numbered, and a read is applied
    /// only if no later load's was already, so an older read finishing late never overwrites a newer one, never raises
    /// the fill signal again and never reports a false ending.
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var appliedPositionsGeneration = 0
    @ObservationIgnored private var appliedOrdersGeneration = 0
    /// The reload the trading stream asked for, and whether another was asked for while it ran.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false

    var unrealizedTotal: Double { positions.reduce(0) { $0 + $1.unrealized } }
    var equity: Double? { account.map { Amount.units($0.balance, decimals: 6) + unrealizedTotal } }

    func change24h(for market: PerpMarket) -> Double? {
        guard let c = context[market.id], c.prev24h > 0 else { return nil }
        return (market.mark - c.prev24h) / c.prev24h * 100
    }

    func poll(env: AppEnvironment, address: Address?) async {
        while !Task.isCancelled {
            await load(env: env, address: address)
            try? await Task.sleep(for: .seconds(8))
        }
    }

    /// The user closed this market's position on `side`, or sent an order that closes it (`PerpCloseOrder.closes`: a
    /// reduce-only order, or one on the other side of the position), from this app: its disappearance is expected, and
    /// the app-wide watcher stays quiet about it. Noted when the close is sent, before the next poll can see the position
    /// gone (GT-9).
    func noteUserClose(_ perpId: Int, closing side: PositionSide) { alerts?.noteUserClose(perpId, closing: side) }

    /// A close noted as sent never left the device: the position's disappearance is news again.
    func forgetUserClose(_ perpId: Int) { alerts?.forgetUserClose(perpId) }

    /// A reload the trading stream asked for (an order's result came in): one at a time, and one more if asked again
    /// meanwhile. The poll keeps reading every 8 s as before.
    func reloadSoon(env: AppEnvironment, address: Address?) async {
        guard reloadTask == nil else { reloadPending = true; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.reloadPending = false
                await self.load(env: env, address: address)
            } while self.reloadPending && !Task.isCancelled
            self.reloadTask = nil
        }
        reloadTask = task
        await task.value
    }

    func load(env: AppEnvironment, address: Address?) async {
        perpl = env.perpl
        alerts = env.alerts
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        defer { loading = false }
        async let ctx = env.perpl.context()
        if address != diffOwner {
            // Another account: its positions are not "new fills" or "closes" of the previous one's.
            diffOwner = address
            watch = PerpPositionWatch()
        }
        do {
            let fetched = try await env.perpl.markets()
            markets = fetched
            env.perplTrading.noteMarkets(fetched)
            error = nil
            if let address {
                async let collateralTask = env.perpl.collateral(of: address)
                let acct = try await env.perpl.account(address)
                account = acct
                if let acct {
                    async let p = env.perpl.positions(acct, markets: fetched)
                    async let o = env.perpl.openOrders(acct, markets: fetched)
                    // A failed read returns nil (keep the last good list); only diff for fills on a successful read.
                    if let fresh = try? await p, generation > appliedPositionsGeneration {
                        appliedPositionsGeneration = generation
                        detectChanges(fresh, stillOpen: Set(acct.positionPerpIds), trading: env.perplTrading)
                        positions = fresh
                        let readAt = Date()
                        positionsReadAt = readAt
                        // Margin sent over the trading connection whose result wasn't confirmed: the chain's word on it.
                        env.perplTrading.marginPositionsRead(fresh, at: readAt, owner: address)
                    }
                    if let freshOrders = try? await o, generation > appliedOrdersGeneration {
                        appliedOrdersGeneration = generation
                        orders = freshOrders
                        // Only a successful chain read forgets an order Perpl's list showed gone.
                        env.perplTrading.chainOrdersRead(freshOrders)
                    }
                    // Reconcile the app's recorded TP/SL: a trigger lives while its market has a position or a resting
                    // entry, so a fired/closed trigger drops off instead of lingering — pruned only while Perpl's live
                    // list can confirm it (offline, an echo may be the only trace of a trigger still armed).
                    let openPerpIds = Set(positions.map(\.perpId)).union(orders.map(\.perpId))
                    triggers = TriggerStore.reconcile(owner: address, openPerpIds: openPerpIds, verified: env.perplTrading.ordersAreLive)
                } else if generation > appliedPositionsGeneration {
                    appliedPositionsGeneration = generation
                    appliedOrdersGeneration = generation
                    positions = []
                    positionsReadAt = Date()
                    orders = []
                    triggers = TriggerStore.reconcile(owner: address, openPerpIds: [], verified: env.perplTrading.ordersAreLive)
                    watch = PerpPositionWatch()
                }
                collateral = (try? await collateralTask) ?? collateral
            } else {
                account = nil
                positions = []
                orders = []
                triggers = []
                watch = PerpPositionWatch()
            }
        } catch {
            self.error = describe(error)
        }
        if let list = try? await ctx { context = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) }) }
    }

    /// What changed since the last good read (`PerpPositionWatch`): a position that opened or grew raises the fill
    /// signal, so the trade screen can jump to Positions; one the account no longer holds has Perpl trading cancel the
    /// TP/SL it leaves behind, in case the stream's own report was missed (security audit GT-2). Neither posts a notice:
    /// the app-wide watcher (`AlertCenter`) posts the fill and the close on any screen, including this one.
    private func detectChanges(_ fresh: [PerpPosition], stillOpen: Set<Int>, trading: PerplTrading) {
        let changes = watch.update(fresh, stillOpen: stillOpen)
        for ended in changes.ended { trading.positionClosedOnChain(marketId: ended.perpId, isLong: ended.side == .long) }
        for position in changes.filled {
            lastFilledPerpId = position.perpId
            fillSignal &+= 1
        }
    }
}

/// Deposit into or withdraw from the Perpl account.
struct CollateralSheet: View {
    enum Kind { case deposit, withdraw }
    let kind: Kind
    let model: PerpsModel
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var showConfirm = false

    private var raw: BigUInt { Amount.parse(amountText, decimals: 6) ?? 0 }
    private var limit: BigUInt { kind == .deposit ? model.collateral.wallet : (model.account.map { $0.balance - min($0.balance, $0.locked) } ?? 0) }
    /// A first deposit with no account yet is really account creation — the plan calls `createAccount`, not `depositCollateral`.
    private var isCreating: Bool { kind == .deposit && model.account == nil }
    /// What's wrong with the amount, in the app's language.
    private var problem: String? {
        if raw == 0 { return nil }
        if raw > limit { return kind == .deposit ? tr("Not enough AUSD in your wallet.") : tr("More than your available balance.") }
        if kind == .deposit, model.account == nil, raw < Perpl.minimumDeposit { return tr("The first deposit must be at least 10 AUSD.") }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(title: "0" as String, text: $amountText, token: .ausd) { Haptics.selection(); amountText = Amount.exact(limit, decimals: 6) }
                } header: {
                    Text(isCreating ? "Open your Perpl account" : (kind == .deposit ? "Deposit AUSD" : "Withdraw AUSD"))
                } footer: {
                    if isCreating {
                        // The Perps screen's first run: opening the account is where someone new to Perps starts. A problem
                        // with the amount takes the explanation's place, and the link stays while it's typed.
                        VStack(alignment: .leading, spacing: 4) {
                            if let problem { Text(verbatim: problem) }
                            else { Paragraph("Your first deposit opens your Perpl account. Minimum 10 AUSD. In wallet: \(NumberStyle.units(limit, decimals: 6)) AUSD.") }
                            LearnMoreLink(.depositAndWithdraw)
                        }
                    }
                    else if let problem { Text(verbatim: problem) }
                    else if kind == .deposit { Text("In wallet: \(NumberStyle.units(limit, decimals: 6)) AUSD") }
                    else { Text("Available: \(NumberStyle.units(limit, decimals: 6)) AUSD") }
                }
            }
            .navigationTitle(isCreating ? tr("Create Account") : (kind == .deposit ? tr("Deposit") : tr("Withdraw")))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { showConfirm = true }.disabled(raw == 0 || problem != nil) }
            }
            .sheet(isPresented: $showConfirm) {
                ConfirmationSheet(title: isCreating ? "Create Trading Account" : (kind == .deposit ? "Confirm Deposit" : "Confirm Withdrawal"), confirmTitle: isCreating ? "Create Account" : (kind == .deposit ? "Deposit" : "Withdraw"), build: { kind == .deposit ? env.perpl.depositPlan(amountCNS: raw, hasAccount: model.account != nil) : env.perpl.withdrawPlan(amountCNS: raw) }, onDone: { dismiss(); Task { await model.load(env: env, address: session.address) } },
                                  onCompleted: { hash in Activity.record(ActivityRecord(kind: kind == .deposit ? .deposit : .withdraw, title: isCreating ? tr("Opened trading account") : (kind == .deposit ? tr("Deposited to Perps") : tr("Withdrew from Perps")), subtitle: "\(NumberStyle.units(raw, decimals: 6)) AUSD", hash: hash, section: "perps", usd: Amount.units(raw, decimals: 6)), owner: session.address) },
                                  intent: kind == .deposit ? .perplDeposit(amount: raw) : .perplWithdraw) {
                    DetailRow("Amount", verbatim: "\(NumberStyle.units(raw, decimals: 6)) AUSD")
                    DetailRow(kind == .deposit ? "To" : "From", "Perpl Exchange")
                    if kind == .deposit, model.account == nil { DetailRow("Account", "Opens a new trading account") }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Mark price sampled from the Exchange contract at evenly spaced blocks over the past day, at `clock`'s pace.
enum MarkPriceHistory {
    static func load(market: PerpMarket, rpc: RPCClient, clock: BlockClock, points: Int = 48) async -> [PricePoint] {
        guard let data = try? ABI.encodeCall("getPerpetualInfo(uint256)", [.uint(market.id)]), let latest = try? await rpc.blockNumber() else { return [] }
        let secondsPerBlock = await clock.secondsPerBlock()
        let span = min(latest, BlockClock.blocks(in: 86_400, secondsPerBlock: secondsPerBlock))
        let step = span / UInt64(points)
        let blocks = (0...points).map { latest - span + UInt64($0) * step }
        let call = CallRequest(to: Perpl.exchange, data: data)
        guard let results = try? await rpc.ethCalls(blocks.map { (call, BlockTag.number($0)) }) else { return [] }
        let types = try? ABIType.parseList("(string,string,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int16,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256,bool)")
        guard let types else { return [] }
        let now = Date()
        return zip(blocks, results).compactMap { block, result in
            guard case .success(let raw) = result, let info = try? ABI.decode(raw, types).first else { return nil }
            let mark = Amount.units(info[11].uint, decimals: market.priceDecimals)
            guard mark > 0 else { return nil }
            let age = Double(latest - block) * secondsPerBlock
            return PricePoint(block: block, time: now.addingTimeInterval(-age), usd: mark)
        }
    }
}
