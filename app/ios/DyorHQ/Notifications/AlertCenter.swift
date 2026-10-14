import DyorKit
import Foundation

/// The app's one alert watcher while DyorHQ is open (build 17, N2): it checks the signed-in wallet's price alerts and its
/// open Perpl positions — margin warnings, fills and closes — on any screen, not only on the screen that shows them.
/// There is no push: while DyorHQ is in the background or closed, iOS suspends it and nothing is checked; a check runs at
/// once when the app comes back to the foreground. The rules are DyorKit's (`AlertLoop`, `PriceAlertCheck`, `PerpRisk`,
/// `PerpRiskWatch`, `PerpPositionWatch`, `PerpEndingNotice`, `PerpAlertText`), so `swift test` pins them.
///
/// One loop at a time: RootView binds the account signed in (`bind`), which starts the loop, keeps it for the same
/// account, and stops it on a sign-out or an account switch. Each loop is a numbered run (`AlertLoop`); after every read
/// it checks it is still the newest run for the account it was started for before it posts or changes anything, so a
/// run that outlives its account never posts for it.
@MainActor
final class AlertCenter {
    private var loop = AlertLoop()
    private var task: Task<Void, Never>?
    /// The sleep between checks, so a return to the foreground can end it early (`enteredForeground`).
    private var sleeper: (run: Int, task: Task<Void, Never>)?
    private var wakeRequested = false
    private var foreground = true

    private weak var env: AppEnvironment?
    private var signedIn: () -> Address? = { nil }
    private var canAct: () -> Bool = { false }

    // What one run knows. A new run (another account) starts with none of it.
    private var positions = PerpPositionWatch()
    private var risk = PerpRiskWatch()
    private var markets: [PerpMarket] = []
    private var marketsReadAt: Date?
    /// Markets with an order resting at the last read of the account's orders that closes the position held there
    /// (`PerpCloseOrder`): reduce-only, or on the other side of the position.
    private var restingCloseMarkets: Set<Int> = []
    /// Positions seen ended whose notice waits for the trading stream (`PerpEndingNotice.wait`).
    private var pendingEndings: [Int: (position: PerpPosition, since: Date, restingClose: Bool)] = [:]
    /// Positions the user closed, or sent an order that closes, from this app — and when.
    private var userCloses = PerpUserCloses()
    /// Orders the app sent that can grow a position, and the fills they announced themselves (`PerpExpectedFills`): a
    /// growth an order's own notice explains is quiet, one an order still waiting for its result may explain waits.
    private var expectedFills = PerpExpectedFills()
    /// Growths seen while an order there was still expected, by market: decided again when that order's result is in
    /// (`reconsiderFills`), or at the next check.
    private var pendingFills: [Int: (position: PerpPosition, growth: Double, since: Date)] = [:]
    /// Price alerts this run fired: never fired twice, even before their removal is read back.
    private var firedPriceAlerts: Set<UUID> = []
    private var lastPerps: Date?
    private var lastPrices: Date?

    /// Follows the account signed in (nil when none): starts the loop for a new account, keeps the one watching this
    /// account, stops it when no one is signed in. `signedIn` is read again before a price alert fires; `canAct` is false
    /// for a watched (watch-only) wallet, whose alerts never suggest an action it can't take.
    func bind(owner: Address?, env: AppEnvironment, signedIn: @escaping () -> Address?, canAct: @escaping () -> Bool) {
        self.env = env
        self.signedIn = signedIn
        self.canAct = canAct
        switch loop.bind(owner) {
        case .keep:
            return
        case .stop:
            stopRun()
        case .start(let run):
            stopRun()
            guard let owner else { return }
            task = Task { [weak self] in await self?.watch(run: run, owner: owner) }
        }
    }

    /// The app went to the background: checks pause until it is back.
    func enteredBackground() { foreground = false }

    /// The app is back in the foreground: everything is checked at once, not at the next tick.
    func enteredForeground() {
        guard !foreground else { return }
        foreground = true
        wakeRequested = true
        sleeper?.task.cancel()
    }

    /// The user closed `perpId`'s position on `side`, or sent an order that closes it (`PerpCloseOrder.closes`), from this
    /// app: its ending is expected, not news.
    func noteUserClose(_ perpId: Int, closing side: PositionSide) { userCloses.note(perpId, closing: side, at: Date()) }

    /// A close noted as sent never left the device: the position's ending is news again.
    func forgetUserClose(_ perpId: Int) { userCloses.forget(perpId) }

    /// An order sent from this app can grow `perpId`'s position on `side` by up to `growth`; its result is expected by
    /// `until`. Until then a growth there waits for the order's own notice rather than racing it.
    func expectFill(_ id: UUID, perpId: Int, side: PositionSide, growth: Double, until: Date) {
        expectedFills.expect(id, perpId: perpId, side: side, growth: growth, until: until)
    }

    /// The order posted its own fill notice for `size` of growth: the watcher stays quiet about that much.
    func fillAnnounced(_ id: UUID, size: Double) { expectedFills.announced(id, size: size, at: Date()) }

    /// The order's result is in and it posts no fill notice: a growth there is the watcher's to announce.
    func releaseFill(_ id: UUID) { expectedFills.release(id) }

    /// The watcher announced a fill on that side of the market since `since` (an order's late fill then stays quiet).
    func watcherAnnounced(perpId: Int, side: PositionSide, since: Date) -> Bool {
        expectedFills.watcherAnnounced(perpId: perpId, side: side, since: since)
    }

    /// An order's result just came in: the growths that waited for it are decided at once (no read).
    func reconsiderFills() {
        guard !pendingFills.isEmpty, preferences?.postsFills == true, signedIn() != nil else { return }
        postPendingFills(now: Date())
    }

    private func stopRun() {
        task?.cancel()
        task = nil
        sleeper?.task.cancel()
        sleeper = nil
        wakeRequested = false
        positions = PerpPositionWatch()
        risk = PerpRiskWatch()
        markets = []
        marketsReadAt = nil
        restingCloseMarkets = []
        pendingEndings = [:]
        userCloses = PerpUserCloses()
        expectedFills = PerpExpectedFills()
        pendingFills = [:]
        firedPriceAlerts = []
        lastPerps = nil
        lastPrices = nil
    }

    private func watch(run: Int, owner: Address) async {
        var woke = true
        while !Task.isCancelled, loop.mayPost(run: run, owner: owner) {
            if foreground {
                if AlertLoop.due(last: lastPerps, interval: AlertLoop.perpsInterval, now: Date(), woke: woke) {
                    lastPerps = Date()
                    await checkPerps(run: run, owner: owner)
                }
                if loop.mayPost(run: run, owner: owner), AlertLoop.due(last: lastPrices, interval: AlertLoop.priceInterval, now: Date(), woke: woke) {
                    lastPrices = Date()
                    await checkPrices(run: run, owner: owner)
                }
            }
            woke = await pause(AlertLoop.perpsInterval, run: run)
        }
    }

    /// Sleeps `seconds`, or less when the app comes back to the foreground; true when it was woken. A run that is no
    /// longer the newest returns at once, and never touches the newest run's sleep or wake.
    private func pause(_ seconds: TimeInterval, run: Int) async -> Bool {
        guard loop.run == run else { return false }
        if wakeRequested { wakeRequested = false; return true }
        let sleep = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
        sleeper = (run, sleep)
        await sleep.value
        // A newer run owns the sleep and the wake now.
        guard loop.run == run else { return false }
        sleeper = nil
        defer { wakeRequested = false }
        return wakeRequested
    }

    private var preferences: AlertPreferences? {
        guard let settings = env?.settings else { return nil }
        return AlertPreferences(notificationsEnabled: settings.notificationsEnabled, fills: settings.notifyFills,
                                priceAlerts: settings.notifyPriceAlerts, marginWarnings: settings.notifyMargin)
    }

    // MARK: Price alerts

    /// Checks the account's price alerts on the prices every screen shows (DyorHQ coins on their own curve or pool), fires
    /// the ones crossed and removes them. A price that can't be read never fires and never removes its alert.
    private func checkPrices(run: Int, owner: Address) async {
        guard let env, preferences?.checksPriceAlerts == true else { return }
        let alerts = PriceAlertStore.all(owner: owner)
        guard !alerts.isEmpty else { return }
        let tokens = alerts.map { Token(address: $0.token, symbol: $0.symbol, name: $0.symbol, decimals: $0.decimals) }
        guard let prices = try? await env.prices.prices(for: tokens) else { return }
        // The account may have changed during the read: its alerts are not this one's to fire.
        guard loop.mayPost(run: run, owner: owner), NotificationHub.shared.owner == owner, preferences?.checksPriceAlerts == true else { return }
        // Read again: an alert deleted during the read doesn't fire.
        let current = PriceAlertStore.all(owner: owner)
        let checks = current.map { PriceAlertCheck.Alert(id: $0.id, token: $0.token, target: $0.target, above: $0.above) }
        let firing = PriceAlertCheck.firing(checks, prices: prices.mapValues(\.usd), readFor: owner, signedIn: signedIn(), alreadyFired: firedPriceAlerts)
        for check in firing {
            guard let alert = current.first(where: { $0.id == check.id }), let price = prices[alert.token]?.usd else { continue }
            Notifications.priceAlert(symbol: alert.symbol, above: alert.above, target: alert.target, price: price)
            firedPriceAlerts.insert(alert.id)
        }
        PriceAlertStore.removeFired(Set(firing.map(\.id)), owner: owner)
    }

    // MARK: Perps

    /// Reads the account's open positions — the reads the Perps screen makes — and posts what changed: an order that
    /// filled, a position that ended (unless the trading stream already said how), and a margin warning that rose. A read
    /// that fails changes nothing.
    private func checkPerps(run: Int, owner: Address) async {
        guard let env else { return }
        let perpl = env.perpl
        let account: PerpAccount?
        do { account = try await perpl.account(owner) } catch { return }
        var fresh: [PerpPosition] = []
        var resting: Set<Int>?
        if let account, !account.positionPerpIds.isEmpty {
            // The markets (decimals and maintenance margin), read again every five minutes, and at once for a market not
            // read yet.
            let stale = marketsReadAt.map { Date().timeIntervalSince($0) > 300 } ?? true
            let missing = account.positionPerpIds.filter { id in !markets.contains { $0.id == id } }
            if stale || !missing.isEmpty {
                guard let read = try? await perpl.markets(ids: Self.marketIds(including: account.positionPerpIds)) else { return }
                guard loop.mayPost(run: run, owner: owner) else { return }
                markets = read
                marketsReadAt = Date()
                env.perplTrading.noteMarkets(read)
            }
            do { fresh = try await perpl.positions(account, markets: markets) } catch { return }
            // Only a market with a position can hold a close order that matters here: reduce-only, or on the other side
            // of the position, which Perpl nets against it.
            let held = markets.filter { account.positionPerpIds.contains($0.id) }
            if let orders = try? await perpl.openOrders(account, markets: held) { resting = PerpCloseOrder.restingCloseMarkets(orders: orders, positions: fresh) }
        }
        guard loop.mayPost(run: run, owner: owner), signedIn() == owner, let preferences else { return }
        let now = Date()

        let changes = positions.update(fresh, stillOpen: Set(account?.positionPerpIds ?? []))
        for ended in changes.ended {
            // The TP/SL that position leaves behind, in case the stream's own report was missed (security audit GT-2).
            env.perplTrading.positionClosedOnChain(marketId: ended.perpId, isLong: ended.side == .long)
            pendingEndings[ended.perpId] = (ended, now, restingCloseMarkets.contains(ended.perpId))
        }
        if let resting { restingCloseMarkets = resting } else if account?.positionPerpIds.isEmpty ?? true { restingCloseMarkets = [] }

        if preferences.postsFills {
            // Growths that waited for an order's own result: past its deadline they are the watcher's to announce.
            postPendingFills(now: now)
            for position in changes.filled {
                // One notice per fill: an order sent from this app announces its own (`PerplOrderTracker`).
                let growth = changes.growth[position.perpId] ?? position.size
                switch expectedFills.decide(perpId: position.perpId, side: position.side, growth: growth, tolerance: lotTolerance(position.perpId), now: now) {
                case .quiet: continue
                case .wait: holdFill(position, growth: growth, now: now); continue
                case .announce: expectedFills.watcherAnnounced(perpId: position.perpId, side: position.side, at: now)
                }
                Notifications.perpOrder(.filled, side: position.side == .long
                                            ? tr(LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]"))
                                            : tr(LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]")),
                                        market: "\(asset(position.perpId, symbol: position.symbol))-PERP", perpId: position.perpId)
            }
        } else {
            pendingFills = [:]
        }

        for (perpId, ending) in pendingEndings.sorted(by: { $0.key < $1.key }) {
            let notice = PerpEndingNotice.decide(endedAt: ending.since, now: now, userClosedAt: userCloses.closedAt(ending.position),
                                                 explainedByStream: env.perplTrading.endingExplained(marketId: perpId),
                                                 streamLive: env.perplTrading.positionsAreLive, restingClose: ending.restingClose)
            if notice == .wait { continue }
            pendingEndings[perpId] = nil
            if let text = PerpAlertText.ending(notice, position: ending.position, asset: asset(perpId, symbol: ending.position.symbol)) {
                Activity.record(ActivityRecord(kind: .perp, title: text.title, subtitle: text.body, hash: nil, section: "perps",
                                               reference: PerpAlertText.reference(perpId: perpId)), owner: owner)
            }
        }

        guard preferences.checksMargin else { risk.reset(); return }
        let maintenance = Dictionary(markets.compactMap { market in market.maintMarginFraction.map { (market.id, $0) } }, uniquingKeysWith: { first, _ in first })
        for notice in risk.update(fresh, maintenance: maintenance) {
            let text = PerpAlertText.risk(notice, asset: asset(notice.position.perpId, symbol: notice.position.symbol), canAct: canAct())
            NotificationHub.shared.post(kind: .perp, title: text.title, body: text.body, route: .perps,
                                        reference: PerpAlertText.reference(perpId: notice.position.perpId), owner: owner)
        }
    }

    /// A growth that waits for an order's own result; a second growth there meanwhile adds to it.
    private func holdFill(_ position: PerpPosition, growth: Double, now: Date) {
        if let held = pendingFills[position.perpId], held.position.side == position.side {
            pendingFills[position.perpId] = (position, held.growth + growth, held.since)
        } else {
            pendingFills[position.perpId] = (position, growth, now)
        }
    }

    /// Decides the growths that waited again: quiet when the order's own notice explained them, announced once the order
    /// is no longer expected.
    private func postPendingFills(now: Date) {
        for (perpId, pending) in pendingFills.sorted(by: { $0.key < $1.key }) {
            let side = pending.position.side
            switch expectedFills.decide(perpId: perpId, side: side, growth: pending.growth, tolerance: lotTolerance(perpId), now: now) {
            case .wait:
                continue
            case .quiet:
                pendingFills[perpId] = nil
            case .announce:
                pendingFills[perpId] = nil
                expectedFills.watcherAnnounced(perpId: perpId, side: side, at: now)
                Notifications.perpOrder(.filled, side: side == .long
                                            ? tr(LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]"))
                                            : tr(LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]")),
                                        market: "\(asset(perpId, symbol: pending.position.symbol))-PERP", perpId: perpId)
            }
        }
    }

    /// Half a lot of `perpId`'s market: two sizes closer than this are the same size.
    private func lotTolerance(_ perpId: Int) -> Double {
        guard let market = markets.first(where: { $0.id == perpId }) else { return 1e-9 }
        return 0.5 * pow(10, -Double(market.lotDecimals))
    }

    /// The app's markets, plus any market the account holds a position in that Perpl added after this build.
    private static func marketIds(including held: [Int]) -> [Int] {
        let listed = PerplService.markets.map(\.id)
        return listed + held.filter { !listed.contains($0) }
    }

    private func asset(_ perpId: Int, symbol: String) -> String {
        markets.first { $0.id == perpId }?.asset ?? symbol
    }
}
