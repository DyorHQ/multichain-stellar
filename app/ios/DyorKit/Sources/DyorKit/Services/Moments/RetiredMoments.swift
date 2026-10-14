import BigInt
import Foundation

/* Retired Moments cohorts (`MomentsAddresses.retiredMainnet`), CLAIM-ONLY. Cohorts 1 and 2 snapshotted the retired
   beneficiaries at publish (platform 0xf4D4…, treasury 0x5282… whose key leaked); cohort 3 pays the current fees wallet
   0x15ED… and treasury 0x5aDb…, and is retired because the v2 contracts replaced it (`MomentsAddresses.retirement`).
   Either way collecting, expiring, retrying a graduation, running a buyback, platform / treasury withdrawals and trading
   on a retired pool are all out of reach from here: on cohorts 1 and 2 each of them either pays the retired wallets or
   feeds a pool whose hook does, and the app serves no past cohort beyond what its people are owed. What stays is
   exactly that — vested coins, and the creator's own proceeds and pool fees. The service below is v1 (`generation`),
   so it never sends a v2-only getter to a retired cohort. */

/// The only writes a retired cohort allows.
public enum RetiredMomentAction: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// `vesting.claim(id)`: mints the caller's vested coins (its collects and, for the creator, the allocation).
    case claim
    /// `collect.withdrawCreator(id)`: the collect-time creator share, paid to the creator only.
    case withdrawCreatorProceeds
    /// `hook.withdrawCreator(id)`: the creator's share of the pool fees, paid to the creator only.
    case withdrawCreatorFees

    public var id: String { rawValue }
}

/// A retired Moment the wallet still has something in, keyed by (factory, id).
public struct RetiredMomentPosition: Sendable, Hashable, Identifiable {
    public let row: MomentPortfolioRow
    /// Collect-time creator share still to withdraw (non-zero only for the creator).
    public let creatorProceeds: BigUInt
    /// Pool fees still to withdraw (non-zero only for the creator).
    public let creatorFees: BigUInt
    /// When the position was read (unix seconds): a Moment past its deadline has missed graduation from then on.
    public let asOf: Int

    public init(row: MomentPortfolioRow, creatorProceeds: BigUInt, creatorFees: BigUInt, asOf: Int = Int(Date().timeIntervalSince1970)) {
        self.row = row
        self.creatorProceeds = creatorProceeds
        self.creatorFees = creatorFees
        self.asOf = asOf
    }

    public var info: MomentInfo { row.moment }
    public var key: MomentKey { row.moment.key }
    public var id: MomentKey { key }
    /// Vested coins claimable now (only a graduated Moment vests).
    public var claimable: BigUInt { info.graduated ? row.claimable : 0 }
    /// Creator USDC waiting: collect proceeds plus pool fees.
    public var creatorWithdrawable: BigUInt { creatorProceeds + creatorFees }
    /// Something to claim or hold: coins claimable or still vesting, creator withdrawals, editions or coins in the
    /// wallet, or coins promised by a Moment that may still graduate. The promise of a Moment that missed graduation
    /// (expired, or collecting past its deadline, which nothing in the app expires on a retired cohort) never vests,
    /// so on its own it does not count.
    public var isOpen: Bool {
        if claimable > 0 || creatorWithdrawable > 0 || row.nftBalance > 0 || row.coinBalance > 0 { return true }
        return !info.missedGraduation(at: asOf) && row.entitlement > row.claimed
    }
}

/// One retired cohort. Reads go through its own `MomentsService` (its contracts, and its deployment block for history
/// scans); the only transactions it can build are `RetiredMomentAction`s against its own vesting, collect and hook.
/// The service stays internal so nothing in the app can reach a collect / expire / retry / buyback / platform or
/// treasury plan for a retired Moment.
public struct RetiredMoments: Sendable {
    public let addresses: MomentsAddresses
    let service: MomentsService

    /// `clock` turns its history's blocks into times: the app's one session clock, or its own when nil. `cache` shares the
    /// cohort's list between the screens that read it (`ChainCache`), and `store` keeps its Moments' records and text,
    /// frozen like the cohort, on the device (`MomentStatics`), so only their state is read again.
    public init(rpc: RPCClient, addresses: MomentsAddresses, logsRPC: RPCClient? = nil, clock: BlockClock? = nil, cache: ChainCache? = nil, store: ChainStore? = nil) {
        self.addresses = addresses
        service = MomentsService(rpc: rpc, addresses: addresses, logsRPC: logsRPC, clock: clock, cache: cache, store: store)
    }

    public var factory: Address { addresses.factory }
    /// Why the cohort is retired (what its pages say).
    public var retirement: MomentsRetirement { addresses.retirement ?? .replaced }

    // MARK: Reads

    /// The cohort's Moments, newest first (`list`), for a reader that doesn't ask whether any were left out.
    public func moments() async throws -> [MomentInfo] {
        try await list().moments
    }

    /// The cohort's Moments, newest first, read from the chain: every pinned one (`MomentLink.Cohort.finalMomentCount`,
    /// whose coins are `MomentsAddresses.retiredMainnetCoins`), always, by id, then up to `laterLimit` of the newest
    /// published after the pin — cohort 3's publishing is not paused (owner decision 2026-09-28). However many Moments
    /// are published after the pin, none can push a pinned one off the list and hide what its holders are owed. `cut` is
    /// true when more than `laterLimit` were published after the pin: the oldest of those are not in `moments`
    /// (`positions` then also reads the account's own among them).
    public func list() async throws -> (moments: [MomentInfo], cut: Bool) {
        try await service.moments(pinned: MomentLink.Cohort(factory: factory)?.finalMomentCount ?? 0, later: Self.laterLimit)
    }

    /// How many of the Moments published after a cohort's pin are read (`list`): as many as build 16 read of a retired
    /// cohort in all (its newest 200), so whatever the counts, every id build 16 read is read here too.
    static let laterLimit = 200

    /// Every Moment of `cohorts`, in their order (`moments`), the cohorts read side by side, and whether every cohort was
    /// read. A cohort whose read fails keeps its Moments from `previous` (an earlier read's, of any cohorts; none when there
    /// was none) and makes `complete` false: a cohort is never left out unsaid.
    public static func moments(of cohorts: [RetiredMoments], keeping previous: [MomentInfo] = []) async -> (moments: [MomentInfo], complete: Bool) {
        let reads = await withTaskGroup(of: (Int, Result<[MomentInfo], Error>).self) { group in
            for (i, cohort) in cohorts.enumerated() {
                group.addTask { (i, await ERC20.captured { try await cohort.moments() }) }
            }
            var out = [Result<[MomentInfo], Error>](repeating: .failure(ChainListUnread(.moment)), count: cohorts.count)
            for await (i, read) in group { out[i] = read }
            return out
        }
        var out: [MomentInfo] = []
        var complete = true
        for (cohort, read) in zip(cohorts, reads) {
            switch read {
            case .success(let moments):
                out += moments
            case .failure:
                complete = false
                out += previous.filter { $0.moment.factory == cohort.factory }
            }
        }
        return (out, complete)
    }

    /// A refreshed `MomentInfo` for an id of THIS cohort.
    public func info(id: BigUInt) async throws -> MomentInfo? {
        try await service.info(id: id)
    }

    /// Fresh `MomentInfo`s for many ids of THIS cohort, in one read and one hydration (`MomentsService.infos`).
    public func infos(ids: [BigUInt]) async throws -> [MomentInfo] {
        try await service.infos(ids: ids)
    }

    /// The account's stake in one of this cohort's Moments; a Moment of another cohort is refused rather than read
    /// under the wrong contracts.
    public func accountView(_ info: MomentInfo, account: Address) async throws -> MomentAccountView {
        guard info.moment.factory == factory else { throw MomentsService.MomentsError.unknownMoment }
        return try await service.accountView(info, account: account)
    }

    /// The Moments of this cohort the account still has something in (see `RetiredMomentPosition.isOpen`), newest first,
    /// among `moments` (Moments a caller already read; this cohort's are kept, and `cut` says whether that read left
    /// Moments out) or, when nil, the cohort's own `list`. When the list was cut, the Moments of this cohort the account
    /// collected, claimed, withdrew from or published that aren't in it are read by id and counted too: from `history` when
    /// the caller has it read in full — the app's history store scans every cohort for the wallet already
    /// (`WalletHistoryScans.moments`) — else from this cohort's own scan (`history(account:)`). That history is a log scan,
    /// and a Moment the account only received by transfer is in none of it, so the positions of a cut list may still miss
    /// one: `complete` is then false. A scan or a read of those Moments that fails leaves them out (the list's positions
    /// stay; `complete` is false already). A list that wasn't cut scans nothing.
    public func positions(account: Address, moments: [MomentInfo]? = nil, cut: Bool = false, history known: MomentsAccountHistory? = nil) async throws
        -> (positions: [RetiredMomentPosition], complete: Bool) {
        let read: (moments: [MomentInfo], cut: Bool)
        if let moments { read = (moments.filter { $0.moment.factory == factory }, cut) } else { read = try await list() }
        var list = read.moments
        if read.cut {
            let own: MomentsAccountHistory
            if let known { own = known } else { own = await history(account: account).history }
            let missing = Self.ownIds(own, factory: factory).subtracting(list.map(\.id))
            if !missing.isEmpty {
                list += (try? await service.infos(ids: missing.sorted(by: >))) ?? []
                list.sort { $0.id > $1.id }
            }
        }
        guard !list.isEmpty else { return ([], !read.cut) }
        let portfolio = try await service.portfolio(account: account, moments: list)
        return (Self.positions(rows: portfolio.rows, moments: list, account: account), !read.cut)
    }

    /// The ids of this cohort's Moments that `history` shows the account in: its collects, claims, withdrawals and
    /// publishes.
    static func ownIds(_ history: MomentsAccountHistory, factory: Address) -> Set<BigUInt> {
        let keys = history.collects.map(\.key) + history.claims.map(\.key) + history.withdrawals.map(\.key) + history.publishes.map(\.key)
        return Set(keys.filter { $0.factory == factory }.map(\.id))
    }

    /// Everything the account did on this cohort since its deployment block, every record carrying this factory, and
    /// whether it was read in full (`MomentsService.history(account:fromBlock:)`, newest first).
    public func history(account: Address) async -> (history: MomentsAccountHistory, complete: Bool) {
        await service.history(account: account)
    }

    // MARK: The only writes

    public func plan(_ action: RetiredMomentAction, momentId: BigUInt, symbol: String) -> [TransactionStep] {
        Self.plan(action, momentId: momentId, symbol: symbol, addresses: addresses)
    }

    /// One call, no approval, no value: a vesting claim, or a creator withdrawal (the contracts pay `msg.sender` and
    /// only when it is the Moment's creator), always to this cohort's own contracts.
    static func plan(_ action: RetiredMomentAction, momentId: BigUInt, symbol: String, addresses: MomentsAddresses) -> [TransactionStep] {
        switch action {
        case .claim:
            return [.call(TransactionRequest(to: addresses.vesting, data: MomentsABI.calldata(MomentsABI.Vesting.claim, [.uint(momentId)])), label: L10n.string(LocalizedStringResource("Claim \(symbol)", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The value is the symbol of a Moment's coin, whose vested coins are claimed.")))]
        case .withdrawCreatorProceeds:
            return [.call(TransactionRequest(to: addresses.collect, data: MomentsABI.calldata(MomentsABI.Collect.withdrawCreator, [.uint(momentId)])), label: L10n.tr("Withdraw creator proceeds"))]
        case .withdrawCreatorFees:
            return [.call(TransactionRequest(to: addresses.hook, data: MomentsABI.calldata(MomentsABI.Hook.withdrawCreator, [.uint(momentId)])), label: L10n.tr("Withdraw creator fees"))]
        }
    }

    /// Pure half of `positions`. The portfolio rows are matched to their Moments by (factory, id); a Moment the
    /// account only created (no allocation, nothing collected or held) has no row, so its creator proceeds and pool
    /// fees get one here. `now` decides which Moments have missed graduation (`RetiredMomentPosition.isOpen`).
    static func positions(rows: [MomentPortfolioRow], moments: [MomentInfo], account: Address, now: Int = Int(Date().timeIntervalSince1970)) -> [RetiredMomentPosition] {
        let rowsByKey = Dictionary(rows.map { ($0.moment.key, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [RetiredMomentPosition] = []
        for info in moments {
            let isCreator = info.moment.creator == account
            let proceeds = isCreator ? info.ledger.creatorClaimable : 0
            let fees = isCreator ? (info.pool?.creatorFees ?? 0) : 0
            let row = rowsByKey[info.key]
                ?? (proceeds + fees > 0 ? MomentPortfolioRow(moment: info, entitlement: 0, claimed: 0, claimableCollector: 0, claimableCreator: 0, nftBalance: 0, coinBalance: 0, isCreator: true) : nil)
            guard let row else { continue }
            let position = RetiredMomentPosition(row: row, creatorProceeds: proceeds, creatorFees: fees, asOf: now)
            if position.isOpen { out.append(position) }
        }
        return out
    }
}
