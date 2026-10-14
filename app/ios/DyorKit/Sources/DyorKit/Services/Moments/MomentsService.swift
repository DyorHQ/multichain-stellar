import BigInt
import Foundation

/// A wallet that can sign a raw 32-byte digest — what a Permit2 collect needs. Both the Privy embedded wallet and an
/// imported local wallet provide it in the app.
public protocol MomentsPermitSigner: Sendable {
    var address: Address { get }
    /// Returns the 65-byte `[r ‖ s ‖ v]` signature as `0x`-hex with `v` as 27/28.
    func signDigest(_ digest: Data) async throws -> String
}

/// The Moments client: every read comes straight from the contracts through Multicall3, every write is a
/// `TransactionStep` plan for `TransactionSender`. A port of the web app's `moments/reads.ts` + `actions.ts`; the
/// derivations are identical so both clients agree to the wei.
public actor MomentsService {
    public let rpc: RPCClient
    /// Where event history is read; a local fork keeps logs on the same node.
    public let logsRPC: RPCClient
    public let addresses: MomentsAddresses
    /// Turns block numbers into the times the history shows, and a Moment's age into blocks.
    public let clock: BlockClock
    let multicall: Multicall
    /// The reads the app's screens share (`ChainCache`): the cohort's list of Moments is read once for every screen that
    /// asks within its time (`moments(limit:)`, and a retired cohort's `moments(pinned:later:)`). Nil reads it every
    /// time, as a test does.
    let cache: ChainCache?
    /// Where each settled Moment's record and text are kept between launches (`MomentStatics`): a refresh reads only its
    /// ledger, editions, entitlements and graduation. Nil reads them every time.
    let store: ChainStore?
    /// The device clock: which Moments are settled enough to keep (`ChainSettled`).
    private let now: @Sendable () -> Date
    /// What `store` keeps of this cohort, by id, as of `staticsEpoch` (nil until read).
    private var statics: [BigUInt: MomentStatics] = [:]
    private var staticsEpoch: Int?
    /// The count this service last read (`counted`): which Moments the next list read expects to be in range, so it reads
    /// their state with the count. Only a guess: a count that moved is read and used.
    private var lastTotal: Int?

    public init(rpc: RPCClient, addresses: MomentsAddresses, logsRPC: RPCClient? = nil, clock: BlockClock? = nil,
                cache: ChainCache? = nil, store: ChainStore? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rpc = rpc
        self.addresses = addresses
        let text = rpc.url.absoluteString
        let local = text.contains("127.0.0.1") || text.contains("localhost")
        self.logsRPC = logsRPC ?? (local ? rpc : RPCClient(url: LaunchpadService.defaultLogsRPC))
        self.clock = clock ?? BlockClock(rpc: rpc)
        multicall = Multicall(rpc: rpc)
        self.cache = cache
        self.store = store
        self.now = now
    }

    public nonisolated var isDeployed: Bool { addresses.isDeployed }

    public enum MomentsError: Error, LocalizedError, Equatable {
        case notDeployed
        case unknownMoment
        case notCollecting(String)
        case signerRequired
        /// A publish without the terms hash the review screen read: nothing is built.
        case termsNotReviewed

        public var errorDescription: String? {
            switch self {
            case .notDeployed: return L10n.tr("Moments are not live on this network yet.")
            case .unknownMoment: return L10n.tr("That Moment does not exist.")
            case .notCollecting(let why): return why
            case .signerRequired: return L10n.tr("Sign in with a wallet that can sign to collect.")
            case .termsNotReviewed: return L10n.tr("The Moments terms couldn't be verified, so nothing was published. Review them again.")
            }
        }
    }

    // MARK: - Policy

    /// The policy, the link base, the counts and any pending proposal in one multicall; on a v2 factory the same
    /// aggregate also reads `termsHash()`, `guardian()` and `guardianPaused()`, so every term and the hash that binds them
    /// come from one block. A v1 factory is never asked for them (the calls would revert and fail the whole read).
    ///
    /// With the app's shared reads (`cache`) the terms are read at most once a minute (`ChainCache.TTL.terms`): the board
    /// polls every 20 s, and their values change only through a proposal queued for 48 hours. A publish stays bound to the
    /// terms its review showed (`publishPlan`'s `termsHash`, MO-4), so terms read a minute ago can never publish under
    /// others. A pull to refresh and a settled transaction read them again (`ChainCache.invalidate`); a read that fails is
    /// never kept.
    public func policy() async throws -> MomentPolicy? {
        guard let cache else { return try await readPolicy() }
        return try await cache.value("moments.\(addresses.factory.hex).terms", ttl: ChainCache.TTL.terms) { try await self.readPolicy() }
    }

    /// `policy()` read now.
    private func readPolicy() async throws -> MomentPolicy? {
        guard isDeployed else { return nil }
        let f = addresses.factory
        let v2 = addresses.generation >= .v2
        var calls = [
            MomentsABI.call(f, MomentsABI.Factory.policy, returns: MomentsABI.policyFlat),
            MomentsABI.call(f, MomentsABI.Factory.momentCount, returns: "uint256"),
            MomentsABI.call(f, MomentsABI.Factory.publishingPaused, returns: "bool"),
            // Strict: the base is compared with DyorHQ's and hashed into `termsHash()` (`MomentPolicy.publishBlock`).
            MomentsABI.call(f, MomentsABI.Factory.externalBaseURI, returns: "string", strings: .strict),
            MomentsABI.call(f, MomentsABI.Factory.pendingPolicy, returns: MomentsABI.policyFlat),
            MomentsABI.call(f, MomentsABI.Factory.pendingPolicyAt, returns: "uint64"),
        ]
        if v2 {
            calls += [
                MomentsABI.call(f, MomentsABI.Factory.termsHash, returns: "bytes32"),
                MomentsABI.call(f, MomentsABI.Factory.guardian, returns: "address"),
                MomentsABI.call(f, MomentsABI.Factory.guardianPaused, returns: "bool"),
            ]
        }
        let values = try await multicall.readAll(calls)
        let p = values[0]
        var policy = MomentPolicy(
            threshold: p[0].uint, minPrice: p[1].uint, creatorBps: MomentsABI.int(p[2]), platformBps: MomentsABI.int(p[3]), reserveBps: MomentsABI.int(p[4]),
            maxCreatorAllocBps: MomentsABI.int(p[5]), expiryCreatorBps: MomentsABI.int(p[6]), royaltyBps: MomentsABI.int(p[7]), platform: p[8].address, treasury: p[9].address,
            momentCount: MomentsABI.int(values[1][0]), publishingPaused: values[2][0].bool, externalBaseURI: values[3][0].string,
            termsHash: v2 ? values[6][0].bytes : nil, guardian: v2 ? values[7][0].address : nil, guardianPaused: v2 ? values[8][0].bool : false
        )
        // A proposed policy is pending while pendingPolicyAt is set (0 = none): the time it can first be applied.
        let applicableAt = values[5][0].uint
        if applicableAt > 0 {
            let n = values[4]
            let at = Date(timeIntervalSince1970: TimeInterval(Int(clamping: applicableAt)))
            policy.pending = PendingMomentPolicy(
                threshold: n[0].uint, minPrice: n[1].uint, creatorBps: MomentsABI.int(n[2]), platformBps: MomentsABI.int(n[3]), reserveBps: MomentsABI.int(n[4]),
                maxCreatorAllocBps: MomentsABI.int(n[5]), expiryCreatorBps: MomentsABI.int(n[6]), royaltyBps: MomentsABI.int(n[7]), platform: n[8].address, treasury: n[9].address,
                applicableAt: at, lapsesAt: v2 ? at.addingTimeInterval(TimeInterval(MomentsConstants.policyApplyWindowSeconds)) : nil
            )
        }
        return policy
    }

    // MARK: - Moments

    /// The newest Moments first: every Moment the cohort counts in that range. One whose text can't be read shows
    /// stand-ins (`hydrate`); a read that doesn't answer for every Moment throws (`ChainListUnread`), never a shorter list.
    ///
    /// With the app's shared reads (`cache`), every screen's list comes from one read of the newest `listingLimit`
    /// (the board, Home, the Portfolio, My Holdings and My Moments asking within `ChainCache.TTL.listing` share it, and
    /// one asking while it is read waits for it), each taking its own newest `limit`. A read that fails is never kept.
    public func moments(limit: Int = 48) async throws -> [MomentInfo] {
        guard let cache, limit > 0, limit <= Self.listingLimit else { return try await readMoments(limit: limit) }
        let shared = try await cache.value("moments.\(addresses.factory.hex).newest", ttl: ChainCache.TTL.listing) {
            try await self.readMoments(limit: Self.listingLimit)
        }
        return Array(shared.prefix(limit))
    }

    /// The most Moments a screen lists (the Portfolio's and My Holdings' 200): what the shared list reads
    /// (`moments(limit:)`), every screen taking its own newest from it.
    public static let listingLimit = 200

    /// `moments(limit:)` read now: the count, the records of the Moments in range (those the device keeps, `records`,
    /// with no read), then their state (`hydrate`). The count is read with the state of the Moments the device keeps that
    /// the last count put in range (`counted`), so a board of settled Moments is one read, not three in a row.
    private func readMoments(limit: Int) async throws -> [MomentInfo] {
        guard isDeployed, limit > 0 else { return [] }
        let guess = lastTotal ?? savedStatics().keys.max().map { Int(clamping: $0) } ?? 0
        let (total, states) = try await counted(expecting: Self.newestIds(total: guess, limit: limit))
        guard total > 0 else { return [] }
        return try await hydrate(try await records(Self.newestIds(total: total, limit: limit)), read: states)
    }

    /// The newest `limit` ids of a cohort that counts `total` Moments, newest first.
    static func newestIds(total: Int, limit: Int) -> [BigUInt] {
        guard total > 0, limit > 0 else { return [] }
        return stride(from: total, through: max(1, total - limit + 1), by: -1).map { BigUInt($0) }
    }

    /// The cohort's `momentCount()` and, in the same aggregate (one block, one round trip), the state `hydrate` reads of
    /// each Moment of `expected` the device keeps (`MomentStatics`, the newest `Multicall.textChunk` of them): what the
    /// list will need if the count is what it was. A Moment whose state didn't all answer is left out of `states`, and
    /// `hydrate` reads it as before; a count that moved leaves the Moments it now puts in range, and not in `states`, to
    /// `hydrate` too, and a Moment past the count is never used. An aggregate the node refuses as a whole (a call in it
    /// reverting the read, out of gas) is read again as the count alone. Throws when the count can't be read.
    private func counted(expecting expected: [BigUInt]) async throws -> (total: Int, states: [BigUInt: [Result<[ABIValue], Error>]]) {
        let saved = savedStatics()
        let kept = Array(expected.compactMap { id in saved[id]?.moment(factory: addresses.factory) }.prefix(Multicall.textChunk))
        let count = MomentsABI.call(addresses.factory, MomentsABI.Factory.momentCount, returns: "uint256")
        let results: [Result<[ABIValue], Error>]
        do {
            results = try await multicall.read([count] + kept.flatMap(stateCalls))
        } catch let error where !kept.isEmpty && ERC20.isCallError(error) {
            results = try await multicall.read([count])
        }
        let total = MomentsABI.int(try results[0].get()[0])
        lastTotal = total
        var states: [BigUInt: [Result<[ABIValue], Error>]] = [:]
        let width = Self.stateCallCount
        guard results.count == 1 + kept.count * width else { return (total, states) }
        for (i, m) in kept.enumerated() where m.id <= BigUInt(total) {
            let slice = Array(results[1 + i * width ..< 1 + (i + 1) * width])
            if slice.allSatisfy({ if case .success = $0 { return true } else { return false } }) { states[m.id] = slice }
        }
        return (total, states)
    }

    /// A retired cohort's Moments (`RetiredMoments.list`), newest first: ids 1…`pinned`, always, and up to `later` of
    /// the newest Moments after them (`retiredIds`), with `cut` true when Moments after the pin were left out. A count
    /// below the pin was read on a node behind (the pinned Moments exist), and throws. With the app's shared reads
    /// (`cache`), the Portfolio, My Holdings and Past Cohorts asking within `ChainCache.TTL.listing` share one read; a read
    /// that fails is never kept.
    func moments(pinned: Int, later: Int) async throws -> (moments: [MomentInfo], cut: Bool) {
        guard let cache else { return try await readMoments(pinned: pinned, later: later) }
        let shared = try await cache.value("moments.\(addresses.factory.hex).pinned.\(pinned).\(later)", ttl: ChainCache.TTL.listing) {
            let read = try await self.readMoments(pinned: pinned, later: later)
            return RetiredMomentsRead(moments: read.moments, cut: read.cut)
        }
        return (shared.moments, shared.cut)
    }

    /// `moments(pinned:later:)` read now, the count with the state of the Moments the device keeps (`counted`): a retired
    /// cohort's Moments are frozen, so after its first read it is one read (two more for a graduated one's pool).
    private func readMoments(pinned: Int, later: Int) async throws -> (moments: [MomentInfo], cut: Bool) {
        guard isDeployed else { return ([], false) }
        let guess = max(pinned, lastTotal ?? savedStatics().keys.max().map { Int(clamping: $0) } ?? 0)
        let (total, states) = try await counted(expecting: Self.retiredIds(total: guess, pinned: pinned, later: later).ids.map { BigUInt($0) })
        guard total >= pinned else { throw ChainListUnread(.moment) }
        let read = Self.retiredIds(total: total, pinned: pinned, later: later)
        guard !read.ids.isEmpty else { return ([], read.cut) }
        return (try await hydrate(try await records(read.ids.map { BigUInt($0) }), read: states), read.cut)
    }

    /// The ids `moments(pinned:later:)` reads of a cohort that counts `total` Moments, newest first: up to `later` of the
    /// newest after the pin, then the pinned ones, `pinned` down to 1. `cut` is true when more than `later` Moments were
    /// published after the pin, so the oldest of them are not among `ids`.
    static func retiredIds(total: Int, pinned: Int, later: Int) -> (ids: [Int], cut: Bool) {
        let first = max(pinned + 1, total - max(0, later) + 1)
        let newer = total >= first ? Array(stride(from: total, through: first, by: -1)) : []
        return (newer + Array(stride(from: pinned, through: 1, by: -1)), first > pinned + 1)
    }

    /// One Moment with the supply identity (`info(id:)`, then `detail(for:)`), or nil when the id is out of range; a
    /// Moment in range that can't be read throws, so its page says so with Retry, never that it doesn't exist. Until
    /// build 23 it read the count, the record and the Moment's whole state a second time after the page's `info(id:)`
    /// had just read them; the page now reads `info(id:)` and `detail(for:)` side by side.
    public func moment(id: BigUInt) async throws -> MomentDetail? {
        guard let info = try await info(id: id) else { return nil }
        return try await detail(for: info)
    }

    /// The detail page's extras for a Moment already read (`info(id:)`, or a list's): its supply identity (`supplyCheck`),
    /// its coin's minted supply and its link, in one read. Its link is `external_url` exactly as the NFT reports it: a v2
    /// NFT keeps the base it was published with (`externalBaseURI()` on the NFT), a v1 NFT reads its factory's current
    /// base, and has no getter of its own. Only what is fixed at publish is taken from `info` (its id, coin and NFT), so
    /// the page reads this beside `info(id:)`, never after it. Another cohort's Moment is refused (its id names a different
    /// Moment here); a read that fails throws.
    public func detail(for info: MomentInfo) async throws -> MomentDetail {
        guard isDeployed else { throw MomentsError.notDeployed }
        guard info.moment.factory == addresses.factory else { throw MomentsError.unknownMoment }
        let m = info.moment
        let baseSource = addresses.generation >= .v2 ? m.nft : addresses.factory
        let extras = try await multicall.readAll([
            MomentsABI.call(addresses.collect, MomentsABI.Collect.supplyCheck, [.uint(m.id)], returns: "uint256,uint256,uint256,uint256,uint256"),
            MomentsABI.call(m.coin, MomentsABI.Coin.totalSupply, returns: "uint256"),
            MomentsABI.call(baseSource, MomentsABI.NFT.externalBaseURI, returns: "string"),
        ])
        let s = extras[0]
        let supply = MomentDetail.Supply(entitlements: s[0].uint, creatorAlloc: s[1].uint, remainderPool: s[2].uint, impliedPool: s[3].uint, collects: MomentsABI.int(s[4]))
        let base = extras[2][0].string
        return MomentDetail(info: info, supply: supply, coinTotalSupply: extras[1][0].uint, externalURL: base.isEmpty ? "" : base + String(m.id))
    }

    /// A refreshed `MomentInfo` for an id (the detail page reads this, a link opens it): nil when the cohort has no such
    /// Moment (the id is past its count, read with the Moment at one block). A Moment in range that can't be read throws
    /// (`ChainListUnread`), so a link to it says "Couldn't open this Moment", with Retry, never "No Moment at this link".
    /// A Moment the device keeps (`MomentStatics`) has its state read with the count, at one block (`counted`): one read.
    public func info(id: BigUInt) async throws -> MomentInfo? {
        guard isDeployed, id > 0 else { return nil }
        if let kept = savedStatics()[id]?.moment(factory: addresses.factory) {
            let (total, states) = try await counted(expecting: [id])
            guard id <= BigUInt(total) else { return nil }
            return try await hydrate([kept], read: states)[0]
        }
        let read = try await multicall.read([
            MomentsABI.call(addresses.factory, MomentsABI.Factory.momentCount, returns: "uint256"),
            MomentsABI.call(addresses.factory, MomentsABI.Factory.getMoment, [.uint(id)], returns: MomentsABI.momentTuple),
        ])
        guard id <= (try read[0].get())[0].uint else { return nil }
        guard case .success(let values) = read[1], let tuple = values.first else { throw ChainListUnread(.thisMoment) }
        return try await hydrate([MomentsABI.moment(id: id, tuple, factory: addresses.factory)])[0]
    }

    /// Fresh `MomentInfo`s for many ids at once: one read of their Moments, then one hydration of them all, in `ids`
    /// order. The ids are Moments known to exist (a coin's `momentIdByCoin`, a pinned retired Moment): one that can't be
    /// read, or any read that fails, throws, so a wallet's Moment is never dropped from its list unsaid.
    public func infos(ids: [BigUInt]) async throws -> [MomentInfo] {
        var seen = Set<BigUInt>()
        let ids = ids.filter { $0 > 0 && seen.insert($0).inserted }
        guard isDeployed, !ids.isEmpty else { return [] }
        return try await hydrate(try await records(ids))
    }

    /// The Moments of `ids`, in `ids` order, in one read. A Moment's record holds no text and every id asked exists, so
    /// the read is all or nothing: one that fails was read on a node behind, and throws. A record the device keeps
    /// (`MomentStatics`: fixed at publish, with no setter on chain) isn't read again.
    private func records(_ ids: [BigUInt]) async throws -> [Moment] {
        let saved = savedStatics()
        var kept: [BigUInt: Moment] = [:]
        for id in ids { if let moment = saved[id]?.moment(factory: addresses.factory) { kept[id] = moment } }
        let missing = ids.filter { kept[$0] == nil }
        if !missing.isEmpty {
            let raws = try await multicall.readAll(missing.map { MomentsABI.call(addresses.factory, MomentsABI.Factory.getMoment, [.uint($0)], returns: MomentsABI.momentTuple) })
            for (id, raw) in zip(missing, raws) { kept[id] = MomentsABI.moment(id: id, raw[0], factory: addresses.factory) }
        }
        return try ids.map { id in
            guard let moment = kept[id] else { throw ChainListUnread(.moment) }
            return moment
        }
    }

    /// The Moment id of a coin, 0 when the address is not a Moment coin.
    public func momentId(coin: Address) async throws -> BigUInt {
        guard isDeployed else { return 0 }
        return try await multicall.readAll([MomentsABI.call(addresses.factory, MomentsABI.Factory.momentIdByCoin, [.address(coin)], returns: "uint256")])[0][0].uint
    }

    /// Moment ids for many token addresses at once (only the ones that are Moment coins are returned).
    public func momentIds(coins: [Address]) async throws -> [Address: BigUInt] {
        guard isDeployed, !coins.isEmpty else { return [:] }
        let unique = Array(Set(coins))
        let values = try await multicall.readAll(unique.map { MomentsABI.call(addresses.factory, MomentsABI.Factory.momentIdByCoin, [.address($0)], returns: "uint256") })
        var out: [Address: BigUInt] = [:]
        for (coin, value) in zip(unique, values) where value[0].uint > 0 { out[coin] = value[0].uint }
        return out
    }

    /// Previews a collect exactly as the contract would settle it. Throws `notCollecting` with a readable reason
    /// when the Moment can't be collected.
    public func quote(id: BigUInt, quantity: Int) async throws -> CollectQuote {
        guard isDeployed else { throw MomentsError.notDeployed }
        let call = MomentsABI.call(addresses.collect, MomentsABI.Collect.quote, [.uint(id), .uint(quantity)], returns: MomentsABI.quoteTuple)
        do {
            let data = try await rpc.ethCall(CallRequest(from: nil, to: call.to, data: call.data, value: 0))
            let values = try ABI.decode(data, call.returnTypes)
            return MomentsABI.quote(values[0])
        } catch let error as RPCError {
            throw MomentsError.notCollecting(Self.collectReason(error))
        }
    }

    /// Custom-error selectors of `MomentCollect`, as sentences.
    static func collectReason(_ error: RPCError) -> String {
        if let data = error.data, let bytes = Data(hex: data), bytes.count >= 4 {
            switch bytes.prefix(4).hexString {
            case ABI.selector("CollectWindowClosed()").hexString: return L10n.tr("The collect window has closed.")
            case ABI.selector("NotCollecting()").hexString: return L10n.tr("This Moment is no longer collecting.")
            case ABI.selector("BadQuantity()").hexString: return L10n.tr("Choose between 1 and \(MomentsConstants.maxBatch) editions.")
            case ABI.selector("UnknownMoment()").hexString: return L10n.tr("That Moment does not exist.")
            default: break
            }
        }
        return RevertReason.describe(error)
    }

    // MARK: - Account

    /// The account's stake in a Moment, read in one round trip: its balances, allowances, entitlement and claims, the
    /// Moment's ledger and fees, and the ids of its editions (up to 50) in one aggregate, its MON balance beside it. Only
    /// what is fixed at publish is taken from `info` (its id, coin, NFT and beneficiaries), so a page reads this beside its
    /// `info(id:)`. Until build 23 the edition ids and the MON balance were a second round trip after the aggregate. Any
    /// value that can't be read throws, the edition ids included when the account holds an edition.
    public func accountView(_ info: MomentInfo, account: Address) async throws -> MomentAccountView {
        guard isDeployed else { throw MomentsError.notDeployed }
        // Moment ids restart at 1 on every factory: another cohort's Moment is refused, never read under this one's id.
        guard info.moment.factory == addresses.factory else { throw MomentsError.unknownMoment }
        let m = info.moment
        let id = m.id
        let usdc = addresses.usdc
        async let monRead = rpc.balance(of: account)
        let read = try await multicall.read([
            try ERC20.balanceOf(usdc, account),
            try ERC20.allowance(usdc, owner: account, spender: addresses.permit2),
            try ERC20.allowance(usdc, owner: account, spender: addresses.collect),
            MomentsABI.call(addresses.vesting, MomentsABI.Vesting.entitlement, [.uint(id), .address(account)], returns: "uint256"),
            MomentsABI.call(addresses.vesting, MomentsABI.Vesting.claimed, [.uint(id), .address(account)], returns: "uint256"),
            MomentsABI.call(addresses.vesting, MomentsABI.Vesting.claimable, [.uint(id), .address(account)], returns: "uint256,uint256"),
            MomentsABI.call(m.coin, MomentsABI.Coin.balanceOf, [.address(account)], returns: "uint256"),
            MomentsABI.call(m.nft, MomentsABI.NFT.balanceOf, [.address(account)], returns: "uint256"),
            MomentsABI.call(addresses.collect, MomentsABI.Collect.ledger, [.uint(id)], returns: MomentsABI.ledgerTuple),
            MomentsABI.call(addresses.hook, MomentsABI.Hook.creatorAccrued, [.uint(id)], returns: "uint256"),
            MomentsABI.call(addresses.hook, MomentsABI.Hook.platformAccrued, [.uint(id)], returns: "uint256"),
            // Asked whatever the balance: an account with no edition gets none back, and its answer is left unused.
            MomentsABI.call(m.nft, MomentsABI.NFT.tokensOfOwner, [.address(account), .uint(0), .uint(50)], returns: "uint256[]"),
        ])
        let values = try read.prefix(11).map { try $0.get() }
        let nftBalance = MomentsABI.int(values[7][0])
        let nftIds: [BigUInt] = nftBalance > 0 ? try read[11].get()[0].elements.map(\.uint) : []
        let mon = try await monRead
        let ledger = MomentsABI.ledger(values[8][0])
        let isCreator = m.creator == account
        let isPlatform = m.platform == account
        let isTreasury = m.treasury == account
        return MomentAccountView(
            usdcBalance: values[0][0].uint, monBalance: mon, permit2Allowance: values[1][0].uint, collectAllowance: values[2][0].uint,
            entitlement: values[3][0].uint, claimed: values[4][0].uint, claimableCollector: values[5][0].uint, claimableCreator: values[5][1].uint,
            coinBalance: values[6][0].uint, nftBalance: nftBalance, nftIds: nftIds,
            creatorProceeds: isCreator ? ledger.creatorClaimable : 0, creatorFees: isCreator ? values[9][0].uint : 0,
            platformProceeds: isPlatform ? ledger.platformClaimable : 0, platformFees: isPlatform ? values[10][0].uint : 0,
            treasuryProceeds: isTreasury ? ledger.treasuryClaimable : 0
        )
    }

    /// Every Moment the account has a stake in: pending (not graduated), claimable now, still vesting, claimed.
    public func portfolio(account: Address, limit: Int = 200) async throws -> MomentPortfolio {
        let moments = try await self.moments(limit: limit)
        return try await portfolio(account: account, moments: moments)
    }

    /// Same, over an already-loaded list of Moments (saves the board re-read).
    public func portfolio(account: Address, moments: [MomentInfo]) async throws -> MomentPortfolio {
        // Only this cohort's Moments: another cohort's id names a different Moment here.
        let moments = moments.filter { $0.moment.factory == addresses.factory }
        guard isDeployed, !moments.isEmpty else { return .empty }
        var calls: [ContractCall] = []
        for info in moments {
            let id = info.id
            calls += [
                MomentsABI.call(addresses.vesting, MomentsABI.Vesting.entitlement, [.uint(id), .address(account)], returns: "uint256"),
                MomentsABI.call(addresses.vesting, MomentsABI.Vesting.claimed, [.uint(id), .address(account)], returns: "uint256"),
                MomentsABI.call(addresses.vesting, MomentsABI.Vesting.claimable, [.uint(id), .address(account)], returns: "uint256,uint256"),
                MomentsABI.call(info.moment.nft, MomentsABI.NFT.balanceOf, [.address(account)], returns: "uint256"),
                MomentsABI.call(info.moment.coin, MomentsABI.Coin.balanceOf, [.address(account)], returns: "uint256"),
                MomentsABI.call(addresses.vesting, MomentsABI.Vesting.creatorClaimed, [.uint(id)], returns: "uint256"),
            ]
        }
        let results = try await multicall.readAll(calls)
        let stride = 6
        var rows: [MomentPortfolioRow] = []
        var pending: BigUInt = 0, claimableTotal: BigUInt = 0, vesting: BigUInt = 0, claimed: BigUInt = 0
        for (i, info) in moments.enumerated() {
            let entitlement = results[i * stride][0].uint
            let claimedAmount = results[i * stride + 1][0].uint
            let claimableCollector = results[i * stride + 2][0].uint
            let claimableCreator = results[i * stride + 2][1].uint
            let nftBalance = MomentsABI.int(results[i * stride + 3][0])
            let coinBalance = results[i * stride + 4][0].uint
            let creatorClaimed = results[i * stride + 5][0].uint
            let isCreator = info.moment.creator == account
            let alloc = isCreator ? info.moment.creatorAllocation : 0
            guard entitlement > 0 || nftBalance > 0 || coinBalance > 0 || alloc > 0 else { continue }
            // `promised` is what this account will be able to claim in total: its collects plus, for the creator, the allocation.
            let promised = entitlement + alloc
            let claimedTotal = claimedAmount + (isCreator ? creatorClaimed : 0)
            let row = MomentPortfolioRow(moment: info, entitlement: promised, claimed: claimedTotal, claimableCollector: claimableCollector, claimableCreator: claimableCreator, nftBalance: nftBalance, coinBalance: coinBalance, isCreator: isCreator)
            rows.append(row)
            if !info.graduated {
                pending += promised
            } else {
                claimableTotal += row.claimable
                vesting += row.vesting
                claimed += claimedTotal
            }
        }
        return MomentPortfolio(rows: rows, pending: pending, claimable: claimableTotal, vesting: vesting, claimed: claimed)
    }

    /// Distinct edition holders and the largest one, from `ownerOf` over editions 1…`editions` (a Moment's NFT mints
    /// them in order and never burns one), `editionChunk` to a read, `Multicall.readsInFlight` reads at a time, up to
    /// `maxEditionsRead`: a Moment with more is counted from its first editions and says so
    /// (`MomentEditionHolders.complete`). Throws when an edition's owner can't be read, so the page says so with Retry.
    /// Until build 23 a failed read came back as no holders ("0") and a Moment's editions past its 400th went uncounted,
    /// both unsaid.
    public func editionHolders(nft: Address, editions: Int) async throws -> MomentEditionHolders {
        let read = min(max(0, editions), Self.maxEditionsRead)
        guard read > 0 else { return MomentEditionHolders(owners: [], complete: true) }
        let items = (1...read).map { [MomentsABI.call(nft, MomentsABI.NFT.ownerOf, [.uint(BigUInt($0))], returns: "address")] }
        let owners = try await multicall.readItems(items, text: [], what: .thisMoment, chunk: Self.editionChunk)
        return MomentEditionHolders(owners: try owners.map { try $0[0].get()[0].address }, complete: read == editions)
    }

    /// Editions' owners per read (`editionHolders`): an address each, so 400 to a read is about 13 KB of answer.
    static let editionChunk = 400
    /// The most editions `editionHolders` reads: 25 reads, 7 round trips at most.
    static let maxEditionsRead = 10_000

    /// The `Published` event of a publish transaction; nil while pending or when the transaction published nothing.
    public func publishResult(transaction hash: Data) async throws -> MomentPublishResult? {
        guard let logs = try await rpc.transactionLogs(hash) else { return nil }
        for log in logs where log.topics.first == MomentsABI.Events.publishedTopic && log.address == addresses.factory {
            if let event = MomentsABI.published(log) { return MomentPublishResult(momentId: event.momentId, creator: event.creator, coin: event.coin, nft: event.nft) }
        }
        return nil
    }

    // MARK: - Plans (writes)

    /// v2 `publish(params, expectedTermsHash)`. `termsHash` is the `MomentPolicy.termsHash` of the terms the review
    /// screen showed (read with them, at one block), never a fresh read: if the terms change before the publish lands
    /// (a matured proposal applied, a new link base), the factory refuses it with `TermsChanged` and nothing is
    /// published. Throws when there is no such hash (a v1 factory, or terms never read) or nothing is deployed.
    public func publishPlan(_ input: MomentPublishInput, termsHash: Data?) throws -> [TransactionStep] {
        guard isDeployed, addresses.generation >= .v2 else { throw MomentsError.notDeployed }
        guard let termsHash, termsHash.count == 32 else { throw MomentsError.termsNotReviewed }
        var salt = [UInt8](repeating: 0, count: 32)
        for i in salt.indices { salt[i] = UInt8.random(in: 0...255) }
        let data = MomentsABI.calldata(MomentsABI.Factory.publish, [MomentsABI.publishParams(input, salt: Data(salt)), .bytes(termsHash)])
        return [.call(TransactionRequest(to: addresses.factory, data: data), label: L10n.tr("Publish \(input.symbol)"))]
    }

    /// Collects `quantity` editions with a Permit2 signature: Permit2 is approved once for USDC (unlimited, the
    /// canonical pattern; the step is skipped when the allowance already covers it), then the collect itself
    /// carries a signed transfer for up to `price × quantity`. The contract only ever pulls the quoted gross.
    public func collectPlan(momentId: BigUInt, quantity: Int, price: BigUInt, signer: any MomentsPermitSigner, symbol: String) async throws -> [TransactionStep] {
        guard isDeployed else { throw MomentsError.notDeployed }
        let maxGross = price * BigUInt(quantity)
        let permit = Permit2Signature.Permit(token: addresses.usdc, amount: maxGross, nonce: Permit2Signature.randomNonce(), deadline: BigUInt(Int(Date().timeIntervalSince1970) + 30 * 60))
        let digest = try Permit2Signature.digest(permit: permit, spender: addresses.collect, permit2: addresses.permit2, chainId: Monad.chainId)
        guard let signature = Data(hex: try await signer.signDigest(digest)), signature.count == 65 else { throw TransactionError.rejected(L10n.tr("The wallet returned an unreadable signature.")) }
        let data = MomentsABI.calldata(MomentsABI.Collect.collectWithPermit2, [.uint(momentId), .uint(quantity), MomentsABI.permit(token: permit.token, amount: permit.amount, nonce: permit.nonce, deadline: permit.deadline), .bytes(signature)])
        let maxUint = (BigUInt(1) << 256) - 1
        return [
            .approve(token: addresses.usdc, spender: addresses.permit2, amount: maxUint, label: L10n.tr("Approve USDC for Permit2")),
            .call(TransactionRequest(to: addresses.collect, data: data), label: L10n.string(LocalizedStringResource("Collect \(quantity) editions of \(symbol)", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The values are the number of editions collected and the Moment's symbol."))),
        ]
    }

    /// The plain-approval path: an exact USDC approval of the collect contract, then `collect`.
    public func collectWithApprovalPlan(momentId: BigUInt, quantity: Int, gross: BigUInt, symbol: String) -> [TransactionStep] {
        let data = MomentsABI.calldata(MomentsABI.Collect.collect, [.uint(momentId), .uint(quantity)])
        return [
            .approve(token: addresses.usdc, spender: addresses.collect, amount: gross, label: L10n.tr("Approve USDC")),
            .call(TransactionRequest(to: addresses.collect, data: data), label: L10n.string(LocalizedStringResource("Collect \(quantity) editions of \(symbol)", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The values are the number of editions collected and the Moment's symbol."))),
        ]
    }

    public func claimPlan(momentId: BigUInt, symbol: String) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.vesting, data: MomentsABI.calldata(MomentsABI.Vesting.claim, [.uint(momentId)])), label: L10n.string(LocalizedStringResource("Claim \(symbol)", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The value is the symbol of a Moment's coin, whose vested coins are claimed.")))]
    }

    public func claimAllPlan(momentIds: [BigUInt]) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.vesting, data: MomentsABI.calldata(MomentsABI.Vesting.claimAll, [.array(momentIds.map { .uint($0) })])), label: L10n.string(LocalizedStringResource("Claim \(momentIds.count) Moments", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The value is how many Moments' vested coins are claimed together.")))]
    }

    public func withdrawCreatorProceedsPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.collect, data: MomentsABI.calldata(MomentsABI.Collect.withdrawCreator, [.uint(momentId)])), label: L10n.tr("Withdraw creator proceeds"))]
    }

    public func withdrawPlatformProceedsPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.collect, data: MomentsABI.calldata(MomentsABI.Collect.withdrawPlatform, [.uint(momentId)])), label: L10n.tr("Withdraw platform proceeds"))]
    }

    public func withdrawTreasuryProceedsPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.collect, data: MomentsABI.calldata(MomentsABI.Collect.withdrawTreasury, [.uint(momentId)])), label: L10n.tr("Withdraw treasury share"))]
    }

    public func withdrawCreatorFeesPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.hook, data: MomentsABI.calldata(MomentsABI.Hook.withdrawCreator, [.uint(momentId)])), label: L10n.tr("Withdraw creator fees"))]
    }

    public func withdrawPlatformFeesPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.hook, data: MomentsABI.calldata(MomentsABI.Hook.withdrawPlatform, [.uint(momentId)])), label: L10n.tr("Withdraw platform fees"))]
    }

    public func retryGraduationPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.graduation, data: MomentsABI.calldata(MomentsABI.Graduation.graduate, [.uint(momentId)])), label: L10n.tr("Retry graduation"))]
    }

    public func expirePlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.collect, data: MomentsABI.calldata(MomentsABI.Collect.expire, [.uint(momentId)])), label: L10n.tr("Expire Moment"))]
    }

    public func buybackPlan(momentId: BigUInt, minCoinOut: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.buyback, data: MomentsABI.calldata(MomentsABI.Buyback.execute, [.uint(momentId), .uint(minCoinOut)])), label: L10n.string(LocalizedStringResource("Run buyback", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. It runs a round of a Moment's buyback.")))]
    }

    // MARK: - Hydration

    /// Ledger, NFT and coin metadata, entitlements and graduation for a page of Moments, in reads of at most
    /// `Multicall.textChunk` Moments, all at once (`Multicall.readItems`, which retries a refused read Moment by Moment), then the
    /// pool state of the graduated ones, one `MomentInfo` per Moment, in order. A Moment's coin name, symbol and
    /// provenance are its creator's: one that can't be read shows a stand-in (`ChainText.unreadable` for the name and
    /// symbol, an empty provenance) and the Moment keeps its numbers and claims. Its ledger, editions, entitlements and
    /// graduation are the protocol's: one that fails means the read didn't happen, and this throws (`ChainListUnread`).
    /// The name, symbol and place are kept as they show (`ChainText.shown`), so none can reorder or hide the app's text
    /// around it; the media links are kept as read. Name links read the names as they are (`MomentDirectory`).
    ///
    /// A Moment the device keeps (`MomentStatics`, the same record) has its text from there, and only its state read: its
    /// ledger, editions, closing, entitlements and graduation, every such Moment's side by side with the full read of the
    /// others. A Moment read in full is kept once it settled (`ChainSettled`) with its text read whole. A kept Moment whose
    /// state was read with the count (`known`, by id: `counted`, the same calls at the count's block) isn't read again.
    private func hydrate(_ moments: [Moment], read known: [BigUInt: [Result<[ABIValue], Error>]] = [:]) async throws -> [MomentInfo] {
        guard !moments.isEmpty else { return [] }
        let epoch = store?.epoch
        let saved = savedStatics()
        let kept = moments.map { m in saved[m.id].flatMap { $0.moment(factory: addresses.factory) == m ? $0 : nil } }
        let stateIndices = moments.indices.filter { kept[$0] != nil && known[moments[$0].id] == nil }
        let stateItems = stateIndices.map { stateCalls(moments[$0]) }
        let fullItems = moments.indices.filter { kept[$0] == nil }.map { m in
            let m = moments[m]
            return [
                MomentsABI.call(addresses.collect, MomentsABI.Collect.ledger, [.uint(m.id)], returns: MomentsABI.ledgerTuple),
                MomentsABI.call(m.nft, MomentsABI.NFT.totalMinted, returns: "uint256"),
                MomentsABI.call(m.nft, MomentsABI.NFT.closed, returns: "bool"),
                MomentsABI.call(m.nft, MomentsABI.NFT.provenance, returns: MomentsABI.provenanceTuple),
                MomentsABI.call(m.coin, MomentsABI.Coin.name, returns: "string"),
                MomentsABI.call(m.coin, MomentsABI.Coin.symbol, returns: "string"),
                MomentsABI.call(addresses.vesting, MomentsABI.Vesting.totalEntitlement, [.uint(m.id)], returns: "uint256"),
                MomentsABI.call(addresses.graduation, MomentsABI.Graduation.isGraduated, [.uint(m.id)], returns: "bool"),
            ]
        }
        let multicall = multicall
        async let stateRead = multicall.readItems(stateItems, text: [], what: .moment)
        let fullResults = try await multicall.readItems(fullItems, text: Self.momentTextCalls, what: .moment)
        let stateResults = try await stateRead
        var states = known
        for (index, result) in zip(stateIndices, stateResults) { states[moments[index].id] = result }
        var partial: [(Moment, MomentLedger, Int, Bool, MomentProvenance, String, String, BigUInt, Bool)] = []
        var settled: [MomentStatics] = []
        var fullAt = 0
        for (m, kept) in zip(moments, kept) {
            if let kept {
                guard let r = states[m.id], r.count == Self.stateCallCount else { throw ChainListUnread(.moment) }
                func value(_ at: Int) throws -> [ABIValue] { try r[at].get() }
                partial.append((m, MomentsABI.ledger(try value(0)[0]), MomentsABI.int(try value(1)[0]), try value(2)[0].bool, Self.shown(kept.provenance),
                                ChainText.shown(kept.name), ChainText.shown(kept.symbol), try value(3)[0].uint, try value(4)[0].bool))
                continue
            }
            let r = fullResults[fullAt]
            fullAt += 1
            func value(_ at: Int) throws -> [ABIValue] { try r[at].get() }
            func text(_ at: Int) -> String? { (try? r[at].get())?.first?.stringOrNil }
            let provenanceRead = (try? value(3)).map { MomentsABI.provenance($0[0]) }
            let read = provenanceRead ?? MomentProvenance(mediaURI: "", mediaHash: Data(), place: "", date: 0, animationURI: "")
            partial.append((m, MomentsABI.ledger(try value(0)[0]), MomentsABI.int(try value(1)[0]), try value(2)[0].bool, Self.shown(read),
                            ChainText.shown(text(4) ?? ChainText.unreadable), ChainText.shown(text(5) ?? ChainText.unreadable), try value(6)[0].uint, try value(7)[0].bool))
            if let provenanceRead, let name = text(4), let symbol = text(5), ChainSettled.isSettled(m.publishedAt, now: now()),
               ChainSettled.isKeepable([name, symbol, provenanceRead.mediaURI, provenanceRead.place, provenanceRead.animationURI]) {
                settled.append(MomentStatics(m, name: name, symbol: symbol, provenance: provenanceRead))
            }
        }
        if let epoch { keepStatics(settled, readSince: epoch) }
        let graduatedIds = partial.filter { $0.8 }.map { $0.0.id }
        let pools = try await self.pools(ids: graduatedIds)
        return partial.map { m, ledger, editions, closed, provenance, name, symbol, entitlements, graduated in
            MomentInfo(
                moment: m, name: name, symbol: symbol, provenance: provenance, ledger: ledger, editions: editions, closed: closed, entitlements: entitlements,
                graduated: graduated, progressBps: MomentsMath.progressBps(reserve: ledger.reserve, threshold: m.threshold, state: graduated ? .graduated : ledger.state),
                pool: pools[m.id]
            )
        }
    }

    /// The calls of `hydrate`'s layout that read the creator's text: provenance, coin name and symbol. The others read
    /// the protocol's values.
    static let momentTextCalls: Set<Int> = [3, 4, 5]

    /// What `hydrate` reads of a Moment the device keeps: its ledger, editions, closing, entitlements and graduation, all
    /// protocol values (nothing of the creator's), `stateCallCount` calls in this order.
    private func stateCalls(_ m: Moment) -> [ContractCall] {
        [
            MomentsABI.call(addresses.collect, MomentsABI.Collect.ledger, [.uint(m.id)], returns: MomentsABI.ledgerTuple),
            MomentsABI.call(m.nft, MomentsABI.NFT.totalMinted, returns: "uint256"),
            MomentsABI.call(m.nft, MomentsABI.NFT.closed, returns: "bool"),
            MomentsABI.call(addresses.vesting, MomentsABI.Vesting.totalEntitlement, [.uint(m.id)], returns: "uint256"),
            MomentsABI.call(addresses.graduation, MomentsABI.Graduation.isGraduated, [.uint(m.id)], returns: "bool"),
        ]
    }

    /// How many calls `stateCalls` makes of one Moment.
    static let stateCallCount = 5

    /// A provenance as read, its place made safe to show (`ChainText.shown`); the media links and hash as read.
    private static func shown(_ read: MomentProvenance) -> MomentProvenance {
        MomentProvenance(mediaURI: read.mediaURI, mediaHash: read.mediaHash, place: ChainText.shown(read.place), date: read.date, animationURI: read.animationURI)
    }

    // MARK: - Kept on the device

    /// The file `store` keeps this cohort's settled Moments in: one per factory, so no two services write one file.
    private var staticsFile: String { "moments-\(addresses.factory.hex.lowercased()).json" }

    /// What the device keeps of this cohort's Moments, by id; none without a store, or on a fork (`ChainStore.keepsFacts`):
    /// a kept Moment's record and text are never checked against the chain again, and a fork restarted while the app runs
    /// can publish other Moments at the same ids, or none at the kept addresses.
    private func savedStatics() -> [BigUInt: MomentStatics] {
        guard let store, store.keepsFacts else { return [:] }
        let epoch = store.epoch
        if staticsEpoch != epoch {
            staticsEpoch = epoch
            statics = [:]
            for entry in store.load(MomentStaticsFile.self, from: staticsFile)?.usable ?? [] {
                if let id = entry.momentId { statics[id] = entry }
            }
        }
        return statics
    }

    /// Keeps `new` and saves the file, unless this device's data was erased since `epoch` (when the read began). Nothing on
    /// a fork (`savedStatics`).
    private func keepStatics(_ new: [MomentStatics], readSince epoch: Int) {
        guard let store, store.keepsFacts, !new.isEmpty else { return }
        _ = savedStatics()
        guard staticsEpoch == epoch else { return }
        var changed = false
        for entry in new {
            guard let id = entry.momentId, statics[id] != entry else { continue }
            statics[id] = entry
            changed = true
        }
        if changed { store.save(MomentStaticsFile(Array(statics.values)), to: staticsFile, epoch: epoch) }
    }

    /// Pool state for graduated Moments: the graduation record, locked liquidity, accrued hook fees, buyback state (on
    /// v2 also the USDC the locker holds for later rounds), and the live sqrt price read straight from the
    /// PoolManager's storage.
    private func pools(ids: [BigUInt]) async throws -> [BigUInt: MomentPool] {
        guard !ids.isEmpty else { return [:] }
        let v2 = addresses.generation >= .v2
        var calls: [ContractCall] = [
            MomentsABI.call(addresses.buyback, MomentsABI.Buyback.minInterval, returns: "uint256"),
            MomentsABI.call(addresses.buyback, MomentsABI.Buyback.minAmount, returns: "uint256"),
        ]
        for id in ids {
            calls += [
                MomentsABI.call(addresses.graduation, MomentsABI.Graduation.record, [.uint(id)], returns: MomentsABI.recordTuple),
                MomentsABI.call(addresses.locker, MomentsABI.Locker.liquidityOf, [.uint(id)], returns: "uint128"),
                MomentsABI.call(addresses.hook, MomentsABI.Hook.creatorAccrued, [.uint(id)], returns: "uint256"),
                MomentsABI.call(addresses.hook, MomentsABI.Hook.platformAccrued, [.uint(id)], returns: "uint256"),
                MomentsABI.call(addresses.hook, MomentsABI.Hook.buybackAccrued, [.uint(id)], returns: "uint256"),
                MomentsABI.call(addresses.buyback, MomentsABI.Buyback.carry, [.uint(id)], returns: "uint256"),
                MomentsABI.call(addresses.buyback, MomentsABI.Buyback.lastRun, [.uint(id)], returns: "uint64"),
            ]
            if v2 { calls.append(MomentsABI.call(addresses.locker, MomentsABI.Locker.heldOf, [.uint(id), .address(addresses.usdc)], returns: "uint256")) }
        }
        let results = try await multicall.readAll(calls)
        let interval = MomentsABI.int(results[0][0])
        let minAmount = results[1][0].uint
        let stride = v2 ? 8 : 7
        var records: [(BigUInt, MomentsABI.GraduationRecord, BigUInt, BigUInt, BigUInt, BigUInt, BigUInt, Int, BigUInt?)] = []
        for (i, id) in ids.enumerated() {
            let base = 2 + i * stride
            records.append((id, MomentsABI.record(results[base][0]), results[base + 1][0].uint, results[base + 2][0].uint, results[base + 3][0].uint, results[base + 4][0].uint, results[base + 5][0].uint, MomentsABI.int(results[base + 6][0]),
                            v2 ? results[base + 7][0].uint : nil))
        }
        // Live prices: one extsload per pool, batched; a failed read falls back to the opening price.
        let priceReads = try? await multicall.read(records.map { MomentsABI.call(addresses.poolManager, MomentsABI.PoolManager.extsload, [.bytes(MomentsABI.slot0(of: $0.1.key.id))], returns: "bytes32") })
        var out: [BigUInt: MomentPool] = [:]
        for (i, entry) in records.enumerated() {
            let (id, record, liquidity, creator, platform, buyback, carry, lastRun, held) = entry
            let key = record.key
            let usdcIs0 = key.currency0 == addresses.usdc
            var sqrtPrice = record.sqrtPriceX96
            var liveRead = false
            if let priceReads, case .success(let values) = priceReads[i] {
                let live = BigUInt(values[0].bytes) & ((BigUInt(1) << 160) - 1)
                if live > 0 { sqrtPrice = live; liveRead = true }
            }
            out[id] = MomentPool(
                key: key, poolId: key.id, usdcIs0: usdcIs0, sqrtPriceX96: sqrtPrice, openingSqrtPriceX96: record.sqrtPriceX96, liquidity: liquidity, seedLiquidity: record.liquidity,
                reserveSeed: record.reserve, poolCoins: record.poolCoins, graduatedAt: record.at, usdcPerCoin: MomentsMath.usdcPerCoin(sqrtPriceX96: sqrtPrice, usdcIs0: usdcIs0),
                creatorFees: creator, platformFees: platform, buybackFees: buyback, buybackCarry: carry, lastBuyback: lastRun, buybackInterval: interval, buybackMin: minAmount,
                heldForLaterRounds: held, livePriceRead: liveRead
            )
        }
        return out
    }

    /// Estimated timestamp of `block` from a later block's and the pace (`BlockClock.time(of:anchor:secondsPerBlock:)`).
    nonisolated static func time(anchor: BlockHeader, block: UInt64, secondsPerBlock: Double) -> Date {
        BlockClock.time(of: block, anchor: anchor, secondsPerBlock: secondsPerBlock)
    }
}

/// A retired cohort's list as one value the shared reads keep (`MomentsService.moments(pinned:later:)`).
struct RetiredMomentsRead: Sendable {
    let moments: [MomentInfo]
    let cut: Bool
}

/// What never changes about a settled Moment (`ChainSettled`), kept on the device (`ChainStore`) so a refresh reads only
/// its state (`MomentsService.hydrate`): its record (`getMoment`, fixed at publish with no setter), and its coin's name and
/// symbol and its NFT's provenance (each set in its contract's constructor), kept as read, never as shown, and only when
/// short (`ChainSettled.maxKeptText`). A retired cohort's Moments are frozen, so they are read from the chain once.
struct MomentStatics: Codable, Hashable, Sendable {
    let id: String
    let creator: Address
    let platform: Address
    let treasury: Address
    let coin: Address
    let nft: Address
    let price: String
    let threshold: String
    let rateNum: String
    let rateDen: String
    let creatorBps: Int
    let platformBps: Int
    let reserveBps: Int
    let creatorAllocBps: Int
    let expiryCreatorBps: Int
    let royaltyBps: Int
    let publishedAt: Int
    let deadline: Int
    let name: String
    let symbol: String
    let mediaURI: String
    /// The keccak-256 of the photo (or video), `0x` hex: what the DyorHQ mirror of it is checked against. Kept as the
    /// registry keeps it (`DyorCoin.mediaHash`), in the app's own sandbox.
    let mediaHash: String
    let place: String
    let date: Int
    let animationURI: String

    init(_ m: Moment, name: String, symbol: String, provenance: MomentProvenance) {
        id = m.id.description
        creator = m.creator
        platform = m.platform
        treasury = m.treasury
        coin = m.coin
        nft = m.nft
        price = m.price.description
        threshold = m.threshold.description
        rateNum = m.rateNum.description
        rateDen = m.rateDen.description
        creatorBps = m.creatorBps
        platformBps = m.platformBps
        reserveBps = m.reserveBps
        creatorAllocBps = m.creatorAllocBps
        expiryCreatorBps = m.expiryCreatorBps
        royaltyBps = m.royaltyBps
        publishedAt = m.publishedAt
        deadline = m.deadline
        self.name = name
        self.symbol = symbol
        mediaURI = provenance.mediaURI
        mediaHash = provenance.mediaHash.hexString
        place = provenance.place
        date = provenance.date
        animationURI = provenance.animationURI
    }

    var momentId: BigUInt? { BigUInt(id, radix: 10).flatMap { $0 > 0 ? $0 : nil } }

    /// The record as `factory` holds it; nil when a number can't be read back (a damaged file: the Moment is then read
    /// in full).
    func moment(factory: Address) -> Moment? {
        guard let id = momentId, let price = BigUInt(price, radix: 10), let threshold = BigUInt(threshold, radix: 10),
              let rateNum = BigUInt(rateNum, radix: 10), let rateDen = BigUInt(rateDen, radix: 10) else { return nil }
        return Moment(id: id, creator: creator, platform: platform, treasury: treasury, coin: coin, nft: nft, price: price, threshold: threshold,
                      rateNum: rateNum, rateDen: rateDen, creatorBps: creatorBps, platformBps: platformBps, reserveBps: reserveBps,
                      creatorAllocBps: creatorAllocBps, expiryCreatorBps: expiryCreatorBps, royaltyBps: royaltyBps, publishedAt: publishedAt,
                      deadline: deadline, factory: factory)
    }

    /// The provenance as read.
    var provenance: MomentProvenance {
        MomentProvenance(mediaURI: mediaURI, mediaHash: Data(hex: mediaHash) ?? Data(), place: place, date: date, animationURI: animationURI)
    }
}

/// The file a `MomentsService` keeps its cohort's settled Moments in (`moments-<factory>.json`): a file of another version
/// is ignored, and an entry that can't be read is left out (`ChainStoreEntry`), so those Moments are read in full again.
struct MomentStaticsFile: Codable {
    static let currentVersion = 1

    let version: Int
    let moments: [MomentStatics]

    init(_ moments: [MomentStatics]) {
        version = Self.currentVersion
        self.moments = moments.sorted { ($0.momentId ?? 0) < ($1.momentId ?? 0) }
    }

    private enum CodingKeys: String, CodingKey { case version, moments }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        moments = try container.decode([ChainStoreEntry<MomentStatics>].self, forKey: .moments).compactMap(\.value)
    }

    /// The Moments to use: none from a file of another version, and none whose record can't be read back.
    var usable: [MomentStatics] {
        version == Self.currentVersion ? moments.filter { $0.moment(factory: .zero) != nil && Data(hex: $0.mediaHash) != nil } : []
    }
}
