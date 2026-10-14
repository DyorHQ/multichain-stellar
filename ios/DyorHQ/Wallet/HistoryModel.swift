import DyorKit
import Foundation
import Observation

/// The wallet's on-chain history as every screen reads it (`WalletHistorySnapshot`), filled in behind the screens.
/// On a wallet the snapshot comes from the store at once, with no network (`WalletHistoryService.cached`, matched with the
/// reference kept for the wallet); what that left unread is read beside the first round (`WalletHistoryService.completed`),
/// and rounds of reading on (`WalletHistoryService.refresh`) follow until every scan has read its window, and every
/// minute or so after that for new blocks. Rounds that
/// couldn't reach the chain or read nothing new come further and further apart, and from the third in a row the
/// snapshot says what is left couldn't be read (`stalled`); a pull, a Retry (`kick`) or a return to the app (`resume`)
/// cuts the wait short. Screens never scan on their own, nor wait for a round: they read `snapshot`, and rebuild from it
/// when `version` moves; a pull awaits only the screen's own reads, and kicks the history on behind them.
///
/// The server's cache of the history (`ServerHistorySync`, while the owner's switch `RemoteFlags.serverHistory` is on and
/// the app has the backend) is read before the first round of each run of them (`readServer`) — after the instant read
/// from the device, never before it — so the rounds read only what it can't vouch for; a scan it is still filling in is
/// polled beside the rounds (`poll`), and once a day what it added is checked against the chain (`spotCheck`).
@Observable
@MainActor
final class HistoryModel {
    private(set) var snapshot = WalletHistorySnapshot.empty
    private(set) var wallet: Address?
    /// Moves whenever `snapshot` changes, for models that rebuild from it.
    private(set) var version = 0
    /// A round is reading now.
    private(set) var refreshing = false
    /// The rounds of reading, nil once they ended (no wallet).
    @ObservationIgnored private var filler: Task<Void, Never>?
    /// Counts the rounds started, so rounds that end clear `filler` only when they are the current ones.
    @ObservationIgnored private var generation = 0
    /// The rounds are waiting out a round that couldn't reach the chain or read nothing: `resume` cuts it short.
    @ObservationIgnored private var backingOff = false
    /// The round reading now, joined by whoever asks for one meanwhile (the rounds, a pull), for the wallet it reads.
    @ObservationIgnored private var inFlight: (wallet: Address, round: Task<WalletHistorySnapshot, Never>)?
    /// Rounds in a row that couldn't reach the chain or read nothing new, across pulls and restarts: from `stalls`
    /// of them, what is published says the rest couldn't be read.
    @ObservationIgnored private var stalls = 0
    /// How far the history had got after the last round, to tell a round that read nothing.
    @ObservationIgnored private var lastProgress = -1.0
    /// Each scan's floor after the last round: a floor that moved down — the transfer scans reading back to the wallet's
    /// first transaction, found beside the first round — makes the window larger and the share read smaller, without the
    /// round having read nothing.
    @ObservationIgnored private var lastFloors: [String: UInt64] = [:]
    /// The curves whose fills count and the tokens' decimals, from the Portfolio's reference data, and the curves a
    /// screen added (`include`); until the Portfolio has read them, what was kept for the wallet (`restoreReference`).
    @ObservationIgnored private(set) var curves: Set<Address> = []
    @ObservationIgnored private var decimals: [Address: Int] = [:]
    /// The wallet the reference was last kept for (`setReference`): each wallet's is kept once it is read, then when it
    /// changes.
    @ObservationIgnored private var referenceKeptFor: Address?
    /// The store's count of erasures when the rounds started on the wallet (`WalletHistoryService.erasureMark`): the
    /// reference is kept only while no erase of this device's data came since, never with a mark read when it is written.
    @ObservationIgnored private var erasureMark: Int?
    /// Rounds published, so a build of the store that started before one never replaces it (`completeFacts`).
    @ObservationIgnored private var roundsPublished = 0
    /// The owner's switch for the server's history (`RemoteFlags.serverHistory`, `setServerHistory`): the one the last read
    /// of the flags said, kept between launches (`ServerHistoryDefaults`); on until a row says otherwise.
    @ObservationIgnored private var readsServerHistory = true
    /// The server's history is to be read before the next round (`readServer`): set when a run of the rounds starts, on a
    /// return to the app, and when the switch turns on.
    @ObservationIgnored private var serverReadDue = false
    /// The app went to the background since it was last active: its return is a new foreground session (`resume`).
    @ObservationIgnored private var backgrounded = false
    /// The polls of a scan the server is still filling in (`poll`), and their count, so one that ends clears `poller`
    /// only when it is the current one.
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var pollers = 0

    /// What one round of reading may spend, per scan: about thirty seconds at the gate's pace (`HistoryCadence.roundSeconds`).
    static let roundBudget = LogsBudget(requests: 40, seconds: HistoryCadence.roundSeconds)
    /// What a pull to refresh spends between rounds (`kick`): the new blocks first, within a few seconds; the rounds read
    /// on after it.
    static let pullBudget = LogsBudget(requests: 12, seconds: 8)
    /// Between rounds once the history is complete: new blocks only, a request or two a scan (`HistoryCadence.topUpPause`,
    /// which the screens' "up to date" is measured against, `HistoryCadence.freshFor`).
    static let topUpPause: Duration = .seconds(HistoryCadence.topUpPause)
    /// Rounds in a row that couldn't reach the chain or read nothing new before the snapshot says what is left
    /// couldn't be read. The wait between such rounds doubles each time, from 20 seconds up to `longestPause`.
    static let stalls = 3
    static let longestPause = 600

    /// Whether some scan is still filling in, with the chain reachable.
    var filling: Bool { snapshot.filling }

    /// Reads the wallet's history from the store and starts filling it in; another wallet starts afresh, nil stops.
    func start(env: AppEnvironment, wallet: Address?) {
        guard wallet != self.wallet || filler == nil else { return }
        filler?.cancel()
        filler = nil
        stopPolling()
        backingOff = false
        stalls = 0
        lastProgress = -1
        lastFloors = [:]
        erasureMark = nil
        self.wallet = wallet
        snapshot = .empty
        version += 1
        guard let wallet else { return }
        run(env: env, wallet: wallet, fromStore: true)
    }

    /// A pull to refresh or a Retry, never waited for: a round reads for thirty seconds or more while the history fills
    /// in, too long to hold a pull's spinner or a screen's own reload, so the screen awaits only its own reads and
    /// follows `version` for what the round brings. Rounds waiting out a stall, or ended, go on at once (`resume`);
    /// between rounds (a second while the history fills in, `topUpPause` once it is complete), a short one for the new
    /// blocks starts (`refresh`); a round reading now is left to finish, and publishes when it does.
    func kick(env: AppEnvironment) {
        guard let wallet else { return }
        if filler == nil || backingOff {
            resume(env: env)
        } else if inFlight?.wallet != wallet {
            Task { [weak self] in await self?.refresh(env: env) }
        }
    }

    /// One round now (`kick`), waited for: the round already reading when there is one, else a short one for the new
    /// blocks (`pullBudget`). A round that read something cuts a stall's wait short; one that read nothing leaves the
    /// rounds to their wait.
    private func refresh(env: AppEnvironment) async {
        guard let wallet else { return }
        let (round, joined) = await round(env: env, wallet: wallet, budget: Self.pullBudget)
        guard self.wallet == wallet else { return }
        if !joined { took(round) }
        publish(round, wallet: wallet, env: env, round: true)
        if stalls == 0 { resume(env: env) }
    }

    /// Rounds that ended, or are waiting out a stall, go on at once (a return to the app, a pull or a Retry, a short
    /// round that read something); nothing while they read. A return from the background is a new foreground session:
    /// the server's history is read again before the next round when the plan calls for it (`readServer`: hours away
    /// leave the scans far behind), and its polls get a new window (`ServerHistorySync.enteredForeground`).
    func resume(env: AppEnvironment) {
        if backgrounded {
            backgrounded = false
            serverReadDue = true
            if let sync = env.serverHistory {
                Task { [weak self] in
                    await sync.enteredForeground()
                    guard let self, let wallet = self.wallet else { return }
                    poll(env: env, wallet: wallet)
                }
            }
        }
        guard let wallet, filler == nil || backingOff else { return }
        filler?.cancel()
        backingOff = false
        run(env: env, wallet: wallet, fromStore: false)
    }

    /// The curves whose fills count and the tokens' decimals, once the Portfolio has read them: the snapshot is built
    /// again from the store with them, and they are kept for the wallet, for the first snapshot after the next launch
    /// (`restoreReference`). A curve is a launch's for good, so the curves are added to, never replaced: a listing that
    /// couldn't read a launchpad never drops the curves another screen added (`include`). What is kept on the device is the
    /// same union, and only while no erase of this device's data came since the rounds started (`erasureMark`).
    func setReference(env: AppEnvironment, curves: Set<Address>, decimals: [Address: Int]) {
        let changed = !curves.isSubset(of: self.curves) || decimals != self.decimals
        self.curves.formUnion(curves)
        self.decimals = decimals
        if let wallet, let erasureMark, changed || referenceKeptFor != wallet {
            referenceKeptFor = wallet
            let reference = WalletHistoryReference(curves: self.curves, decimals: decimals)
            Task { await env.walletHistory.keep(reference: reference, wallet: wallet, since: erasureMark) }
        }
        guard changed else { return }
        rebuild(env: env)
    }

    /// The reference kept for `wallet` (`setReference`), added to what this launch has: the launches' curves and the
    /// tokens' decimals the Portfolio read last time, so the first snapshot counts launch fills and weighs swap legs right
    /// before it has read them again. A curve is a launch's for good and a token's decimals never change, so what is kept
    /// only adds; what this launch read wins.
    private func restoreReference(env: AppEnvironment, wallet: Address) async {
        guard let kept = await env.walletHistory.reference(wallet: wallet), self.wallet == wallet else { return }
        curves.formUnion(kept.curves)
        decimals.merge(kept.decimals) { now, _ in now }
    }

    /// Adds `more` to the curves whose fills count, for a screen that reads a coin's fills (My Launchpad) before the
    /// Portfolio's launches are read, or with a launch they lack: the snapshot is built again from the store, with no
    /// scan, when any is new. Never drops a curve.
    func include(env: AppEnvironment, curves more: Set<Address>) {
        guard !more.isSubset(of: curves) else { return }
        curves.formUnion(more)
        rebuild(env: env)
    }

    /// Builds the snapshot again from the store with the current reference, and publishes it.
    private func rebuild(env: AppEnvironment) {
        guard let wallet else { return }
        let (curves, decimals) = (curves, decimals)
        Task { [weak self] in
            guard let self else { return }
            let rebuilt = await env.walletHistory.cached(wallet: wallet, curves: curves, decimals: decimals)
            guard self.wallet == wallet else { return }
            publish(rebuilt, wallet: wallet, env: env)
        }
    }

    /// Publishes `snapshot` for `wallet`, said to be stalled while the last rounds read nothing (`stalls`). A snapshot
    /// built with curves since added to (a round that started before `include` or `setReference`) is built again from
    /// the store at once, so a coin's fills don't wait a round to count.
    private func publish(_ snapshot: WalletHistorySnapshot, wallet: Address, env: AppEnvironment, round: Bool = false) {
        guard self.wallet == wallet else { return }
        if round { roundsPublished += 1 }
        self.snapshot = stalls >= Self.stalls ? snapshot.stalled() : snapshot
        version += 1
        if snapshot.curves != curves { rebuild(env: env) }
    }

    /// The rounds of reading for `wallet`: first what the store has (`fromStore`), at once and with no network, matched
    /// with the reference kept for the wallet; then what that left unread (`completeFacts`) beside `fill`. `afterReset`:
    /// the entries were reset (`restart`), so the server's history is read again before the first round whatever the time
    /// of the last read, and nothing a read of it under way began with is kept (`ServerHistorySync.reset`).
    private func run(env: AppEnvironment, wallet: Address, fromStore: Bool, afterReset: Bool = false) {
        generation += 1
        let mine = generation
        serverReadDue = true
        filler = Task { [weak self] in
            if afterReset { await env.serverHistory?.reset(wallet: wallet) }
            guard let self else { return }
            if fromStore {
                let mark = await env.walletHistory.erasureMark
                guard !Task.isCancelled, self.wallet == wallet else { return }
                erasureMark = mark
                await restoreReference(env: env, wallet: wallet)
                guard !Task.isCancelled, self.wallet == wallet else { return }
                let cached = await env.walletHistory.cached(wallet: wallet, curves: curves, decimals: decimals)
                guard !Task.isCancelled, self.wallet == wallet else { return }
                publish(cached, wallet: wallet, env: env)
                if cached.swapFactsUnread { completeFacts(env: env, wallet: wallet) }
            }
            await fill(env: env, wallet: wallet)
            if generation == mine { filler = nil }
        }
    }

    /// The instant read left transactions' facts unread (`WalletHistorySnapshot.swapFactsUnread`): they are read now,
    /// beside the first round rather than after it — a round reads for thirty seconds while the history fills in — and the
    /// snapshot is built again from the store with them (`WalletHistoryService.completed`) and published, unless a round
    /// published meanwhile: it read them too, and more. Anything else published meanwhile (`version` moved: the server's
    /// history taken in, `readServer`, or a rebuild after a poll or a new reference) was built from entries newer than the
    /// ones this build read: the snapshot is built again from the store (`rebuild`, no network), with the facts this one
    /// read kept there, rather than published over it — in the first cut of the server's history it rolled the screens
    /// back to the history before the server's was taken in, until the first round published.
    private func completeFacts(env: AppEnvironment, wallet: Address) {
        let rounds = roundsPublished, published = version
        let (curves, decimals) = (curves, decimals)
        Task { [weak self] in
            let completed = await env.walletHistory.completed(wallet: wallet, curves: curves, decimals: decimals)
            guard let self, self.wallet == wallet, roundsPublished == rounds else { return }
            guard version == published else { rebuild(env: env); return }
            publish(completed, wallet: wallet, env: env)
        }
    }

    /// One round of reading for `wallet`: the one under way (`joined`), else a new one within `budget`.
    private func round(env: AppEnvironment, wallet: Address, budget: LogsBudget) async -> (snapshot: WalletHistorySnapshot, joined: Bool) {
        if let inFlight, inFlight.wallet == wallet { return (await inFlight.round.value, true) }
        let round = Task { await env.walletHistory.refresh(wallet: wallet, budget: budget, curves: curves, decimals: decimals) }
        inFlight = (wallet, round)
        refreshing = true
        let snapshot = await round.value
        if inFlight?.round == round {
            inFlight = nil
            refreshing = false
        }
        return (snapshot, false)
    }

    /// Takes in what a round read, by whoever started it: a round that reached the chain and got further sets the
    /// stalls back; one that couldn't, or got no further, counts one more — but for one whose window grew (a floor moved
    /// down, `lastFloors`): its share read is of more blocks than the last round's. A round whose scans are complete
    /// counts one more when the facts of the transactions the swaps leave out couldn't be read either
    /// (`WalletHistorySnapshot.swapFactsFailed`, the archive endpoints refusing): the screens built from the swaps would
    /// otherwise wait at 99% for as long as they refuse, never saying so.
    private func took(_ round: WalletHistorySnapshot) {
        let floors = round.status.compactMapValues(\.floor)
        let widened = floors.contains { id, floor in lastFloors[id].map { floor < $0 } ?? false }
        lastFloors = floors
        if round.complete, !round.swapFactsFailed {
            stalls = 0
            lastProgress = 1
        } else if round.complete || round.unreachable || (!widened && round.progress <= lastProgress) {
            stalls += 1
            lastProgress = max(lastProgress, round.progress)
        } else {
            stalls = 0
            lastProgress = round.progress
        }
    }

    /// How long the rounds wait after `round`: a second while the history fills in — or while transactions' facts are
    /// still left out and the last build read some (`SwapHistoryService.factsPerBuild` a build: a wallet's first launch
    /// with this build reads hundreds, and each waiting a top-up would hold the screens at 99% for minutes) — `topUpPause`
    /// once complete, and after rounds that read nothing a wait that doubles with each (20 seconds up to `longestPause`),
    /// a failing archive included.
    private func pause(after round: WalletHistorySnapshot) -> Duration {
        if stalls > 0 { return .seconds(min(10 << min(stalls, 6), Self.longestPause)) }
        if round.complete, !round.unreadTransactionBlocks.isEmpty, (round.swapFactsRead ?? 0) > 0 { return .seconds(1) }
        return round.complete ? Self.topUpPause : .seconds(1)
    }

    /// Rounds of reading on, until the history is complete, then a top-up every `topUpPause`. A round that couldn't
    /// reach the chain or read nothing new (the endpoints refusing, or resting after throttling) is followed by a
    /// longer wait each time, and from the third in a row (`stalls`) the snapshot says what is left couldn't be
    /// read; a round that reads again sets both back.
    private func fill(env: AppEnvironment, wallet: Address) async {
        while !Task.isCancelled, self.wallet == wallet {
            if serverReadDue {
                serverReadDue = false
                await readServer(env: env, wallet: wallet)
                guard !Task.isCancelled, self.wallet == wallet else { return }
            }
            let (round, joined) = await round(env: env, wallet: wallet, budget: Self.roundBudget)
            guard !Task.isCancelled, self.wallet == wallet else { return }
            if !joined { took(round) }
            let pause = pause(after: round)
            publish(round, wallet: wallet, env: env, round: true)
            poll(env: env, wallet: wallet)
            backingOff = stalls > 0
            try? await Task.sleep(for: pause)
            backingOff = false
        }
    }

    // MARK: The server's history

    /// The owner's switch for the server's history (`RemoteFlags.serverHistory`, applied by `AppEnvironment.apply(_:)` at
    /// launch from what was kept and at each read of the flags). Off: nothing more is read from the server, and its polls
    /// stop; what was taken in stays until the history epoch drops it. Turned on: read before the next round.
    func setServerHistory(_ on: Bool) {
        guard on != readsServerHistory else { return }
        readsServerHistory = on
        if on { serverReadDue = true } else { stopPolling() }
    }

    /// The app went to the background: its return is a new foreground session (`resume`).
    func enteredBackground() {
        backgrounded = true
    }

    /// The owner's history epoch dropped entries the server's history had added (`HistoryStore.apply(epoch:)`, at a read
    /// of the flags): the rounds start over on the wallet from what the store holds now (`restart`), the server read again
    /// before the first.
    func epochReset(env: AppEnvironment) {
        restart(env: env)
    }

    /// The rounds start over on the wallet, from what the store holds now — an epoch reset, a spot check that found the
    /// server's history wrong and forgot the wallet's — with the instant read first, the server's history read again before
    /// the first round whatever the time of the last read (`run`'s `afterReset`), and nothing of a round under way joined
    /// or kept: it read entries that are gone (the store lets its refreshes go, `HistoryStore.forget`). The snapshot isn't
    /// emptied first, as for another wallet: the instant read replaces it at once. The Portfolio's figures saved for the
    /// wallet go too (`PortfolioModel.dropSaved`): built on the history dropped, they were otherwise shown on Home and in the
    /// Portfolio, and saved again, for up to a day.
    private func restart(env: AppEnvironment) {
        guard let wallet else { return }
        env.portfolio.dropSaved(env: env, for: wallet, historyVersion: version)
        filler?.cancel()
        filler = nil
        stopPolling()
        inFlight = nil
        refreshing = false
        backingOff = false
        stalls = 0
        lastProgress = -1
        lastFloors = [:]
        erasureMark = nil
        referenceKeptFor = nil
        run(env: env, wallet: wallet, fromStore: true, afterReset: true)
    }

    /// Before the first round of a run (`fill`): the server's history of the wallet (`ServerHistorySync.beforeRound` — a
    /// full read while some scan doesn't hold what the server could add, a top-up when every one does but far behind, or
    /// nothing), while the owner's switch is on and the app has the backend (`AppEnvironment.serverHistory`). The instant
    /// read from the device was published before it. Waited for, so the first round reads only what the server can't
    /// vouch for — about 2,400 blocks a scan (the 1,200-block trust margin plus the 1,200-block overlap), one rpc2
    /// request — rather than reading the same history from the chain beside it,
    /// minutes of requests on the public endpoints that the adoption would then wait out (it waits for the round under
    /// way, `HistoryStore.adopt`); but never longer than `ServerHistoryPlan.stepSeconds`: past that the rounds start, and
    /// what the read takes in later comes with the next round. What it took in is published at once, so "Reading your
    /// history" goes as soon as the entries it completes are; then the polls start if a scan is still filling in on the
    /// server, and the day's spot check runs beside the rounds.
    private func readServer(env: AppEnvironment, wallet: Address) async {
        guard readsServerHistory, let sync = env.serverHistory else { return }
        let step = Task { await sync.beforeRound(wallet: wallet) }
        let adopted = await ServerHistorySync.value(of: step, within: ServerHistoryPlan.stepSeconds) ?? []
        guard !Task.isCancelled, self.wallet == wallet else { return }
        if !adopted.isEmpty {
            let taken = await env.walletHistory.cached(wallet: wallet, curves: curves, decimals: decimals)
            guard !Task.isCancelled, self.wallet == wallet else { return }
            publish(taken, wallet: wallet, env: env)
        }
        poll(env: env, wallet: wallet)
        spotCheck(env: env, wallet: wallet, sync: sync)
    }

    /// Polls a scan the server is still filling in, beside the rounds, never holding one: each poll when
    /// `ServerHistorySync.nextPoll` says (a minute after the last look, for a quarter of an hour a foreground session),
    /// and what it took in published at once. Nothing while polls run, the switch is off, or nothing is watched.
    private func poll(env: AppEnvironment, wallet: Address) {
        guard poller == nil, readsServerHistory, let sync = env.serverHistory else { return }
        pollers += 1
        let mine = pollers
        poller = Task { [weak self] in
            while !Task.isCancelled, let wait = await sync.nextPoll(wallet: wallet) {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, self?.readsServerHistory == true, self?.wallet == wallet else { break }
                let adopted = await sync.poll(wallet: wallet)
                guard !Task.isCancelled, let self, self.wallet == wallet else { break }
                if !adopted.isEmpty { rebuild(env: env) }
            }
            if let self, self.pollers == mine { self.poller = nil }
        }
    }

    private func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    /// The day's spot check of what the server added (`ServerHistorySync.spotCheck`), beside the rounds: when the chain
    /// disagrees, the wallet's history on the device was forgotten and the server is distrusted for it for a day, so the
    /// rounds start over from the chain alone (`restart`).
    private func spotCheck(env: AppEnvironment, wallet: Address, sync: ServerHistorySync) {
        Task { [weak self] in
            guard await sync.spotCheck(wallet: wallet) == .mismatched, let self, self.wallet == wallet else { return }
            restart(env: env)
        }
    }
}
