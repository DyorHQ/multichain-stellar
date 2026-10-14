import BigInt
import DyorKit
import Foundation
import Observation

/// A bridge deposit sent and not yet settled, persisted per account so tracking survives the app being killed (GL-5).
/// Public details only — hashes, addresses, symbols, amounts — never a key.
struct PendingBridge: Codable, Equatable, Identifiable {
    var id: String { hash }
    /// The source-chain deposit transaction.
    let hash: String
    /// The account that sent it: the only one it is ever tracked or credited for (RS-2).
    let owner: Address
    let depositAddress: String
    let memo: String?
    let fromChainId: String
    let toChainId: String
    let fromName: String
    let toName: String
    let inSymbol: String
    let amountText: String
    let destToken: AuroraToken
    /// The destination balance, asked for just before signing; set once that read answers (`setBaseline`), after the
    /// deposit is already persisted. Nil while it hasn't, or when it failed, which rules out confirming the arrival by
    /// the balance (RI-3).
    var baseline: BigUInt?
    let minOut: BigUInt?
    let usd: Double?
    let sentAt: Date
    /// Another bridge to the same asset was unsettled at some point while this one was: either one's credit could be
    /// read as the other's arrival, so neither is ever confirmed by the balance, only by the bridge's status (RI-3).
    var overlapped = false
    /// The arrival was seen in the destination balance and recorded; the bridge's status is still watched for a refund.
    var arrivedByBalance = false
}

/// Tracks every bridge deposit until it settles, whether or not the Bridge screen is open (GL-5, RI-3, RS-2). A deposit
/// is persisted the moment it is sent, so a relaunch or a return to the foreground resumes its tracking; completion
/// (Portfolio volume, the "Bridge complete" notification) and refunds are recorded whenever they are seen.
///
/// "Arrived" means the destination balance rose by the promised minimum over a baseline asked for just before signing,
/// with no other bridge to the same asset unsettled at any point in this one's life; the bridge's status is still
/// watched afterwards, and a later refund corrects the record. When the bridge reports success but no such delta can be
/// shown (no baseline, an overlapping bridge, or a balance that still hasn't caught up after a few reads), the screen
/// says to check the balance instead. Only the account that sent a deposit
/// tracks or credits it: signing out or switching accounts stops every poll at once, and nothing is recorded for
/// another account.
@Observable
@MainActor
final class BridgeTracker {
    enum Status: Equatable {
        case bridging(AuroraSwapStatus)
        /// Seen in the destination balance: what arrived.
        case arrived(String)
        /// The bridge reports success, but the arrival can't be shown in the balance: check it.
        case unverified(String)
        case settling(String)
        case refunded(String)
        case failed(String)
    }

    /// By source deposit hash, for the deposits tracked since launch.
    private(set) var status: [String: Status] = [:]
    /// The destination-chain settlement transaction, once the bridge names it.
    private(set) var arrivalURL: [String: URL] = [:]

    private let aurora: AuroraIntents
    private let balances: MultiChainBalances
    /// Monad on the app's configured RPC, rather than the public default.
    private let monad: EVMChain
    private var owner: Address?
    /// The running poll per deposit, with an id so a poll cancelled by `bind` can't clear its successor's entry.
    private var polls: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    init(aurora: AuroraIntents, balances: MultiChainBalances, monad: EVMChain) {
        self.aurora = aurora
        self.balances = balances
        self.monad = monad
    }

    // MARK: Lifecycle

    /// Follows the signed-in account: stops every poll (RS-2), then resumes that account's own deposits.
    func bind(owner: Address?) {
        guard owner != self.owner else { return }
        for poll in polls.values { poll.task.cancel() }
        polls = [:]
        status = [:]
        arrivalURL = [:]
        self.owner = owner
        resume()
    }

    /// Resumes every unsettled deposit of the bound account that isn't being polled (at launch, and on each return to
    /// the foreground — iOS suspends the polls in the background).
    func resume() {
        guard let owner else { return }
        for bridge in Self.pending(owner: owner) where polls[bridge.hash] == nil {
            // A week on, a deposit is settled or refunded on the bridge's side: stop asking.
            guard Date().timeIntervalSince(bridge.sentAt) < 7 * 24 * 3600 else { Self.remove(bridge.hash, owner: owner); continue }
            start(bridge)
        }
    }

    /// A deposit just sent: persisted before anything else can go wrong, then polled. Any other unsettled bridge to the
    /// same asset and this one are marked `overlapped` (RI-3).
    func track(_ bridge: PendingBridge) {
        var bridge = bridge
        var list = Self.pending(owner: bridge.owner)
        list.removeAll { $0.hash == bridge.hash }
        for i in list.indices where list[i].destToken.assetId == bridge.destToken.assetId {
            list[i].overlapped = true
            bridge.overlapped = true
        }
        list.append(bridge)
        Self.save(list, owner: bridge.owner)
        status[bridge.hash] = .bridging(.pendingDeposit)
        guard bridge.owner == owner, polls[bridge.hash] == nil else { return }
        start(bridge)
    }

    /// The destination balance asked for before `hash` was signed, once it answers (RI-3): recorded on the persisted
    /// deposit unless it already has one. A read that failed (nil) leaves none. One that answers late can only be too
    /// high (it may include this bridge's own credit), which never confirms an arrival that didn't happen.
    func setBaseline(_ baseline: BigUInt?, for hash: String, owner: Address) {
        guard let baseline else { return }
        var list = Self.pending(owner: owner)
        guard let i = list.firstIndex(where: { $0.hash == hash }), list[i].baseline == nil else { return }
        list[i].baseline = baseline
        Self.save(list, owner: owner)
    }

    private func start(_ bridge: PendingBridge) {
        let id = UUID()
        let task = Task { [weak self] in
            await self?.poll(bridge)
            if self?.polls[bridge.hash]?.id == id { self?.polls[bridge.hash] = nil }
        }
        polls[bridge.hash] = (id, task)
    }

    // MARK: Poll

    private func isCurrent(_ bridge: PendingBridge) -> Bool { !Task.isCancelled && bridge.owner == owner }

    /// About ten minutes of the app running (150 reads, 4 s apart; 20 s apart once the arrival is seen). Tracking that
    /// runs out stays persisted and resumes on the next return to the foreground.
    private func poll(_ start: PendingBridge) async {
        var bridge = start
        var failures = 0
        for _ in 0..<150 {
            guard isCurrent(bridge) else { return }
            do {
                let state = try await aurora.status(depositAddress: bridge.depositAddress, depositMemo: bridge.memo)
                guard isCurrent(bridge) else { return }
                failures = 0
                if let ref = state.swapDetails?.destinationChainTxHashes?.last,
                   let url = ref.explorerUrl.flatMap(URL.init(string:)) ?? chain(bridge.toChainId)?.explorerTx(ref.hash) {
                    arrivalURL[bridge.hash] = url
                }
                switch state.status {
                case .success:
                    if bridge.arrivedByBalance { finish(bridge); return }
                    // The bridge reports success once the destination transaction is mined, and a destination RPC a block
                    // or two behind still reads the old balance: read it a few times before saying to check it.
                    var arrived = await arrival(bridge)
                    for _ in 0..<3 where arrived == nil && provable(bridge) != nil {
                        guard isCurrent(bridge) else { return }
                        try? await Task.sleep(for: .seconds(2))
                        arrived = await arrival(bridge)
                    }
                    guard isCurrent(bridge) else { return }
                    recordCompletion(bridge, usd: state.swapDetails?.amountOutUsd.flatMap(Double.init))
                    let out = state.swapDetails?.amountOutFormatted.map { "\($0) \(bridge.destToken.symbol)" }
                    status[bridge.hash] = arrived.map { .arrived($0) }
                        ?? .unverified(out.map { tr("The bridge reports it complete (\($0)). Check your \(bridge.destToken.symbol) balance on \(bridge.toName) to confirm it arrived.") }
                            ?? tr("The bridge reports it complete. Check your \(bridge.destToken.symbol) balance on \(bridge.toName) to confirm it arrived."))
                    finish(bridge)
                    return
                case .refunded:
                    correct(bridge, title: tr("Bridge refunded"), detail: tr("\(bridge.inSymbol) returned on \(bridge.fromName)"))
                    status[bridge.hash] = .refunded(tr("Bridge refunded — \(state.swapDetails?.refundReason ?? tr("the swap couldn't complete")). Your funds were returned on \(bridge.fromName)."))
                    finish(bridge)
                    return
                case .failed:
                    correct(bridge, title: tr("Bridge failed"), detail: state.swapDetails?.refundReason ?? tr("The bridge could not complete on \(bridge.toName)"))
                    status[bridge.hash] = .failed(state.swapDetails?.refundReason ?? tr("The bridge failed."))
                    finish(bridge)
                    return
                default:
                    // Still in progress, but the funds may already be on the destination: shown by the balance.
                    if !bridge.arrivedByBalance { bridge = await arrivedEarly(bridge) }
                    guard isCurrent(bridge) else { return }
                    if !bridge.arrivedByBalance { status[bridge.hash] = .bridging(state.status) }
                }
            } catch {
                guard isCurrent(bridge) else { return }
                if !bridge.arrivedByBalance { bridge = await arrivedEarly(bridge) }
                guard isCurrent(bridge) else { return }
                failures += 1
                if failures >= 4, !bridge.arrivedByBalance {
                    status[bridge.hash] = .settling(tr("Still settling — this can take a minute. Check your balance on \(bridge.toName); DyorHQ keeps checking while it's open."))
                }
            }
            try? await Task.sleep(for: .seconds(bridge.arrivedByBalance ? 20 : 4))
        }
        guard isCurrent(bridge), !bridge.arrivedByBalance else { return }
        status[bridge.hash] = .settling(tr("Taking longer than usual. Check your balance on \(bridge.toName); DyorHQ checks again each time you open it."))
    }

    /// The arrival seen in the balance while the bridge still says in progress: recorded, shown as arrived, and kept
    /// persisted so the status is still watched for a refund.
    private func arrivedEarly(_ bridge: PendingBridge) async -> PendingBridge {
        guard let arrived = await arrival(bridge), isCurrent(bridge) else { return bridge }
        var updated = bridge
        updated.arrivedByBalance = true
        var list = Self.pending(owner: bridge.owner)
        // Only the flag: the stored baseline and overlap may be newer than this poll's copy.
        if let i = list.firstIndex(where: { $0.hash == bridge.hash }) { list[i].arrivedByBalance = true; Self.save(list, owner: bridge.owner) }
        recordCompletion(updated, usd: nil)
        status[bridge.hash] = .arrived(arrived)
        return updated
    }

    /// What arrived, when the destination balance has risen by at least 95% of the promised minimum over the baseline
    /// asked for before signing. Nil when the arrival can't be shown by the balance (`provable`), or the balance can't
    /// be read.
    private func arrival(_ bridge: PendingBridge) async -> String? {
        guard let stored = provable(bridge), let baseline = stored.baseline, let minOut = stored.minOut, let chain = chain(bridge.toChainId) else { return nil }
        let read = await balances.balances(owner: bridge.owner, chain: chain, tokens: [bridge.destToken])
        guard let now = read[bridge.destToken.assetId], now > baseline else { return nil }
        let credited = now - baseline
        guard credited * 100 >= minOut * 95 else { return nil }
        return "\(NumberStyle.units(credited, decimals: bridge.destToken.decimals)) \(bridge.destToken.symbol)"
    }

    /// The persisted deposit, when its arrival can be shown by the balance: it has a baseline and a minimum, and no other
    /// bridge to the same asset was unsettled at any point in its life (`overlapped`, and checked again now). Read from
    /// storage, not a poll's copy, since the baseline and the overlap are recorded after the poll starts.
    private func provable(_ bridge: PendingBridge) -> PendingBridge? {
        let list = Self.pending(owner: bridge.owner)
        guard let stored = list.first(where: { $0.hash == bridge.hash }), stored.baseline != nil, (stored.minOut ?? 0) > 0, !stored.overlapped,
              !list.contains(where: { $0.hash != bridge.hash && $0.destToken.assetId == bridge.destToken.assetId }) else { return nil }
        return stored
    }

    private func chain(_ auroraId: String) -> EVMChain? { auroraId == monad.auroraId ? monad : EVMChain.byAuroraId(auroraId) }

    // MARK: Records

    /// Portfolio volume and the "Bridge complete" notification, once per deposit, for the account that sent it.
    private func recordCompletion(_ bridge: PendingBridge, usd: Double?) {
        guard !BridgeStore.all(owner: bridge.owner).contains(where: { $0.id == bridge.hash }) else { return }
        BridgeStore.record(BridgeRecord(id: bridge.hash, usd: usd ?? bridge.usd ?? 0, fromChain: bridge.fromName, toChain: bridge.toName,
                                        inSymbol: bridge.inSymbol, outSymbol: bridge.destToken.symbol, time: Date()), owner: bridge.owner)
        Notifications.bridge(amount: "\(bridge.amountText) \(bridge.inSymbol)", from: bridge.fromName, to: bridge.toName)
    }

    /// A refund or failure replaces the send-time Activity row (same hash) and takes back any completion recorded when
    /// the balance rose, so a failed bridge never stays looking like a success.
    private func correct(_ bridge: PendingBridge, title: String, detail: String) {
        BridgeStore.remove(id: bridge.hash, owner: bridge.owner)
        Activity.record(ActivityRecord(kind: .bridge, title: title, subtitle: detail, hash: Data(hex: bridge.hash), section: "bridge"), owner: bridge.owner)
    }

    private func finish(_ bridge: PendingBridge) {
        Self.remove(bridge.hash, owner: bridge.owner)
    }

    // MARK: Storage

    private static func key(_ owner: Address) -> String { "bridge.pending.v1.\(owner.hex)" }

    static func pending(owner: Address) -> [PendingBridge] {
        guard let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([PendingBridge].self, from: data)) ?? []
    }

    private static func save(_ list: [PendingBridge], owner: Address) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(owner))
    }

    private static func remove(_ hash: String, owner: Address) {
        save(pending(owner: owner).filter { $0.hash != hash }, owner: owner)
    }
}
