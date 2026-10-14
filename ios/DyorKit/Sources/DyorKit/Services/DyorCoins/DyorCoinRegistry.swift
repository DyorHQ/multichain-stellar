import BigInt
import Foundation

/// Every DyorHQ coin (`DyorCoin`), read from the factories themselves: each launchpad stack — the live one and every
/// retired one, 0x6B1C included, which is still open on chain — and each Moments cohort, c1–c4 (cohort 3 is still open on
/// chain too). One source for "is this a DyorHQ coin, and what is its picture" for the icons, the badges, the own-coin
/// rule and prices; it reveals nothing about the wallet, since it reads every coin, not the ones held.
///
/// - **Enumeration** (`refresh`), the primary path: each factory's `launchCount()` / `momentCount()`, then the launches
///   (`getLaunches`) or Moments (`getMoment`) not read before, then each new coin's record in its factory, name, symbol
///   and picture — three Multicall3 reads in all today (7 launches, 6 Moments). How far each factory's list has been
///   read is kept (`DyorCoinStore`), so a later refresh reads only the counts and what is new.
/// - **Point proof** (`prove`), for a held address not seen yet: first every factory's count, and a factory whose count
///   is what was read of its list (its checkpoint) has named every coin it has, all of them known here, so it isn't
///   asked about the address. Each other launchpad's `getLaunchedToken(coin)` and cohort's `momentIdByCoin(coin)`; a
///   launch counts when a record exists and names this coin, a Moment when `getMoment(id).coin` is this coin. An answer
///   that is missing makes it unknown — shown as today — never "not DyorHQ"; "not DyorHQ" is kept for this session only,
///   and only after every factory answered. After a complete refresh, a wallet holding a thousand airdropped tokens
///   costs one read (the counts), not one per 22 tokens.
/// - **Ingest** of launches and Moments other screens read (Home, Portfolio, Send, a launch or publish that just
///   settled): each coin not known yet is proven, so only a factory's own record admits one — never a value handed in.
///
/// Membership never comes from anything a token says about itself: no call ever goes to a candidate token until a
/// factory has named it. A coin's name, symbol and picture are its creator's strings, which anyone launching for 5 MON
/// can make as long as a transaction stores, or bytes that aren't text: they are read as a list's text is
/// (`Multicall.readItems`: 20 coins a read, 4 reads in flight, a coin whose read fails read again on its own), decoded
/// leniently (U+FFFD for bytes that aren't text), and a text call that fails however it is read stands in as
/// `ChainText.unreadable`. Once its factory's record names a coin, the coin is admitted whatever its text — the
/// unreadable text then makes its badge a warning (`TokenBadge`), never "DyorHQ Launch" — so no creator's text can hold
/// a factory's list back. Only the factory's own answer can: a record that is empty or names another coin (a node
/// behind the chain) or that couldn't be read stops that list there, to be read again at the next refresh. A count
/// below what was read is a node behind the chain too (the app's failover RPC can land on one): that factory's coins
/// and checkpoint stay and the refresh isn't complete; only a count that stays below it for `lowerCountGrace` (a fork
/// restarted under the same file) has that list dropped and read again from the start. Reads go on
/// the client given (the app's failover RPC), each a single Multicall3 `eth_call`. When to refresh is the app's (at
/// start, every 5 minutes in the foreground, after a launch or publish settles); no view triggers a read.
public actor DyorCoinRegistry {
    /// What the registry can say of an address.
    public enum Membership: Hashable, Sendable {
        /// A DyorHQ coin, as its factory recorded it.
        case dyor(DyorCoin)
        /// Not one: MON, a curated token, or an address every factory answered for without naming it (this session).
        case notDyor
        /// Not known yet: not read, or a read that failed. Shown as today.
        case unknown
    }

    /// The launchpad stacks read, live first (`launchpads(live:)`).
    public nonisolated let launchpads: [LaunchpadAddresses]
    /// The Moments cohorts read, live first (`cohorts(live:)`).
    public nonisolated let cohorts: [MomentsAddresses]
    /// The live launchpad's and cohort's factories (zero while one isn't deployed): every other one is retired.
    nonisolated let liveLaunchpad: Address
    nonisolated let liveCohort: Address
    let multicall: Multicall
    private let store: DyorCoinStore?

    private var coins: [Address: DyorCoin]
    /// How many of each factory's launches or Moments have been read, in the order the factory lists them.
    private(set) var checkpoints: [Address: Int]
    /// Addresses every factory answered for without naming them, this session.
    private var notDyor: Set<Address> = []
    /// The refresh under way, which another joins, with its number.
    private var running: (id: Int, task: Task<Bool, Never>)?
    /// The point proofs under way, by number: `erase` cancels them.
    private var proving: [Int: Task<Void, Never>] = [:]
    private var tasksStarted = 0
    private var lastCompleteRefresh: Date?
    /// Factories whose count came back below their checkpoint, with when that was first seen and not answered otherwise
    /// since (`lowerCountGrace`).
    private var lowerCounts: [Address: Date] = [:]
    /// Bumped by `erase`, so a read that started before it never writes its results back.
    private var epoch = 0
    private var subscribers: [UUID: AsyncStream<[Address: DyorCoin]>.Continuation] = [:]

    /// Sub-calls in one Multicall3 read: 200 launch records measured at about 3.2M gas on mainnet (2026-09-30), well inside
    /// a public RPC's `eth_call` cap.
    static let maxCallsPerRead = 200
    /// New launches or Moments read per factory in one refresh; the rest follow in the next.
    static let maxNewPerRefresh = 500
    /// Launch addresses asked for in one `getLaunches` call.
    static let launchPage = 250
    /// How long a factory's count must stay below what was read before the registry believes it and reads that list
    /// again from the start: ten minutes, long after a node behind the chain (Monad makes a block every 0.4 s) has
    /// caught up. Until then the count is taken as that node's and the coins are kept.
    static let lowerCountGrace: TimeInterval = 600
    /// Where a coin's reads (`launchReads`, `momentReads`) read its creator's text: every call but the first, its
    /// factory's record, which is the only one that must answer (`Multicall.readItems`).
    static let textCalls: Set<Int> = [1, 2, 3]

    /// Reads the live launchpad `live` and cohort `liveMoments` (zero while not deployed) plus every retired one, from
    /// what `store` kept, if anything.
    public init(rpc: RPCClient, live: LaunchpadAddresses = .monadMainnet, liveMoments: MomentsAddresses = .monadMainnet, store: DyorCoinStore? = nil) {
        let launchpads = Self.launchpads(live: live)
        let cohorts = Self.cohorts(live: liveMoments)
        let liveLaunchpad = live.isDeployed ? live.factory : .zero
        let liveCohort = liveMoments.isDeployed ? liveMoments.factory : .zero
        self.launchpads = launchpads
        self.cohorts = cohorts
        self.liveLaunchpad = liveLaunchpad
        self.liveCohort = liveCohort
        multicall = Multicall(rpc: rpc)
        self.store = store
        let kept = store?.load().map { Self.restored($0, launchpads: launchpads, cohorts: cohorts, liveLaunchpad: liveLaunchpad, liveCohort: liveCohort) }
        coins = kept?.coins ?? [:]
        checkpoints = kept?.checkpoints ?? [:]
    }

    /// The live launchpad once it is deployed, then every retired one (`LaunchpadAddresses.retiredStacks`).
    public static func launchpads(live: LaunchpadAddresses) -> [LaunchpadAddresses] {
        (live.isDeployed ? [live] : []) + LaunchpadAddresses.retiredStacks.filter { $0.factory != live.factory }
    }

    /// The live cohort once it is deployed, then every retired one (`MomentsAddresses.retiredMainnet`).
    public static func cohorts(live: MomentsAddresses) -> [MomentsAddresses] {
        (live.isDeployed ? [live] : []) + MomentsAddresses.retiredMainnet.filter { $0.factory != live.factory }
    }

    // MARK: Lookups

    /// The DyorHQ coin at `address`, if known.
    public func coin(_ address: Address) -> DyorCoin? { coins[address] }

    /// Every DyorHQ coin known, by address.
    public var all: [Address: DyorCoin] { coins }

    /// The coins `owner` made: launches its factory records it as deployer of, Moments it created.
    public func coins(createdBy owner: Address) -> [DyorCoin] {
        coins.values.filter { $0.creator == owner }.sorted { $0.address.hex < $1.address.hex }
    }

    /// What is known of `address` now, without a read.
    public func membership(_ address: Address) -> Membership {
        if address.isZero || Token.core(address) != nil { return .notDyor }
        if let coin = coins[address] { return .dyor(coin) }
        return notDyor.contains(address) ? .notDyor : .unknown
    }

    /// The whole list now, then again after every change, for a screen model to follow. The stream ends when its task is
    /// cancelled.
    public func updates() -> AsyncStream<[Address: DyorCoin]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Address: DyorCoin].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        continuation.yield(coins)
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    // MARK: Enumeration

    /// Reads what every factory recorded since the last refresh (at most `maxNewPerRefresh` per factory), `now` being
    /// when. True when the registry then holds every coin the factories had recorded; false when a read failed, a count
    /// came back below what was read (`lowerCountGrace`) or more is left for next time (what was read is kept either
    /// way). A refresh already running is joined, not repeated.
    @discardableResult
    public func refresh(now: Date = Date()) async -> Bool {
        if let running { return await running.task.value }
        tasksStarted += 1
        let id = tasksStarted
        let epoch = self.epoch
        let task = Task { await self.enumerate(now: now) }
        running = (id, task)
        let complete = await task.value
        if running?.id == id { running = nil }
        if epoch == self.epoch { lastCompleteRefresh = complete ? now : nil }
        return complete
    }

    /// `refresh`, unless the last one was complete and finished less than `maxAge` seconds before `now`: one that left
    /// anything unread, or heard a count below what was read, makes the next call read again.
    @discardableResult
    public func refreshIfStale(maxAge: TimeInterval = 300, now: Date = Date()) async -> Bool {
        if let lastCompleteRefresh, now.timeIntervalSince(lastCompleteRefresh) < maxAge { return true }
        return await refresh(now: now)
    }

    /// A launchpad stack or a Moments cohort, as the enumeration reads it.
    private enum Source {
        case launchpad(LaunchpadAddresses)
        case cohort(MomentsAddresses)

        var factory: Address {
            switch self {
            case .launchpad(let stack): return stack.factory
            case .cohort(let cohort): return cohort.factory
            }
        }

        var countCall: ContractCall {
            switch self {
            case .launchpad(let stack): return LaunchpadABI.call(stack.factory, LaunchpadABI.Factory.launchCount, returns: "uint256")
            case .cohort(let cohort): return MomentsABI.call(cohort.factory, MomentsABI.Factory.momentCount, returns: "uint256")
            }
        }
    }

    /// The new coins of one factory, in its list order, and how far its list had been read before.
    private struct Job {
        let source: Source
        let from: Int
        let to: Int
    }

    private func enumerate(now: Date) async -> Bool {
        let epoch = self.epoch
        let sources = launchpads.map(Source.launchpad) + cohorts.map(Source.cohort)
        // 1. How many each factory has recorded. A count below what was read before is a node behind the chain (or one
        //    that answered wrongly): that factory stays as it is and the refresh isn't complete. Only when counts stay
        //    below it for `lowerCountGrace` — another chain's, a fork restarted under the same file — are that factory's
        //    coins dropped and its list read again from the start.
        let counts = await read(sources.map(\.countCall))
        var complete = true
        var jobs: [Job] = []
        var reached = checkpoints
        var dropped: Set<Address> = []
        var lower = lowerCounts
        for (source, result) in zip(sources, counts) {
            guard case .success(let values) = result, let value = values.first else { complete = false; continue }
            let count = LaunchpadABI.int(value)
            let stored = checkpoints[source.factory] ?? 0
            var done = stored
            if count < stored {
                guard let since = lower[source.factory], now.timeIntervalSince(since) >= Self.lowerCountGrace else {
                    if lower[source.factory] == nil { lower[source.factory] = now }
                    complete = false
                    continue
                }
                dropped.insert(source.factory)
                done = 0
            }
            lower[source.factory] = nil
            reached[source.factory] = done
            guard count > done else { continue }
            let to = min(count, done + Self.maxNewPerRefresh)
            if to < count { complete = false }
            jobs.append(Job(source: source, from: done, to: to))
        }
        // 2. Which coins: the new launches' addresses, a page at a time, and the new Moments. These answers are the
        //    factories' own, of a fixed size.
        var listCalls: [ContractCall] = []
        for job in jobs {
            switch job.source {
            case .launchpad(let stack):
                for offset in stride(from: job.from, to: job.to, by: Self.launchPage) {
                    let size = min(Self.launchPage, job.to - offset)
                    listCalls.append(LaunchpadABI.call(stack.factory, LaunchpadABI.Factory.getLaunches, [.uint(BigUInt(offset)), .uint(BigUInt(size))], returns: "address[]"))
                }
            case .cohort(let cohort):
                for id in (job.from + 1)...job.to { listCalls.append(MomentsABI.call(cohort.factory, MomentsABI.Factory.getMoment, [.uint(BigUInt(id))], returns: MomentsABI.momentTuple)) }
            }
        }
        let lists = await read(listCalls)
        var cursor = 0
        func next() -> Result<[ABIValue], Error> {
            defer { cursor += 1 }
            return lists[cursor]
        }
        // Each job's items in list order, cut at the first page or Moment that couldn't be read.
        var items: [[Item]] = []
        for job in jobs {
            var list: [Item] = []
            var whole = true
            switch job.source {
            case .launchpad(let stack):
                for offset in stride(from: job.from, to: job.to, by: Self.launchPage) {
                    let size = min(Self.launchPage, job.to - offset)
                    let page = next()
                    guard whole, case .success(let values) = page, let tokens = values.first?.elements.map(\.address) else { whole = false; continue }
                    list += tokens.prefix(size).map { Item.launch($0, stack) }
                    if tokens.count < size { whole = false }
                }
            case .cohort(let cohort):
                for id in (job.from + 1)...job.to {
                    let answer = next()
                    guard whole, case .success(let values) = answer, let tuple = values.first else { whole = false; continue }
                    list.append(.moment(MomentsABI.moment(id: BigUInt(id), tuple, factory: cohort.factory), cohort))
                }
            }
            items.append(list)
        }
        // 3. Each new coin's record in its factory, name, symbol and picture: one item of four calls per coin, its text
        //    allowed to fail on its own.
        let answers = await readCoins(items)
        // 4. Admit them in list order. A factory's checkpoint moves past each coin its record names, whatever its text; it
        //    stops at the first whose record is empty or names another coin — a node behind the chain answers a coin it
        //    hasn't reached that way — and stays where it was when the factory's records couldn't be read, so those are
        //    read again next time.
        var found: [DyorCoin] = []
        for (index, job) in jobs.enumerated() {
            guard let answers = answers[index] else { complete = false; continue }
            var passed = job.from
            for (item, answer) in zip(items[index], answers) {
                guard let coin = item.coin(answer, retired: item.factory != (item.isLaunch ? liveLaunchpad : liveCohort)) else { break }
                found.append(coin)
                passed += 1
            }
            reached[job.source.factory] = passed
            if passed < job.to { complete = false }
        }
        guard epoch == self.epoch else { return false }
        lowerCounts = lower
        let checkpointsMoved = reached != checkpoints
        checkpoints = reached
        commit(found, dropping: dropped, persistAnyway: checkpointsMoved)
        return complete
    }

    /// Each list's coins read (`Multicall.readItems`), one answer per coin in its layout; nil for a list whose records
    /// couldn't be read. All lists are read together; when a record couldn't be read, each list is read again on its
    /// own, so one factory's trouble holds back only its own list. No answer at all leaves every list unread.
    private func readCoins(_ lists: [[Item]]) async -> [[[Result<[ABIValue], Error>]]?] {
        let all = lists.flatMap { $0 }
        guard !all.isEmpty else { return lists.map { _ in [] } }
        do {
            let answers = try await multicall.readItems(all.map(\.reads), text: Self.textCalls, what: .dyorCoin)
            var out: [[[Result<[ABIValue], Error>]]?] = []
            var at = 0
            for list in lists {
                out.append(Array(answers[at..<at + list.count]))
                at += list.count
            }
            return out
        } catch is ChainListUnread where lists.filter({ !$0.isEmpty }).count > 1 {
            var out: [[[Result<[ABIValue], Error>]]?] = []
            for list in lists {
                out.append(list.isEmpty ? [] : try? await multicall.readItems(list.map(\.reads), text: Self.textCalls, what: .dyorCoin))
            }
            return out
        } catch {
            return lists.map { $0.isEmpty ? [] : nil }
        }
    }

    /// One coin a factory listed, with the factory's stack or cohort.
    private enum Item {
        case launch(Address, LaunchpadAddresses)
        case moment(Moment, MomentsAddresses)

        var factory: Address {
            switch self {
            case .launch(_, let stack): return stack.factory
            case .moment(_, let cohort): return cohort.factory
            }
        }

        var isLaunch: Bool { if case .launch = self { return true } else { return false } }

        var reads: [ContractCall] {
            switch self {
            case .launch(let token, let stack): return DyorCoinRegistry.launchReads(token, stack: stack)
            case .moment(let moment, let cohort): return DyorCoinRegistry.momentReads(moment, cohort: cohort)
            }
        }

        func coin(_ answers: [Result<[ABIValue], Error>], retired: Bool) -> DyorCoin? {
            switch self {
            case .launch(let token, let stack): return DyorCoinRegistry.launchCoin(token, stack: stack, retired: retired, answers: answers)
            case .moment(let moment, let cohort): return DyorCoinRegistry.momentCoin(moment, cohort: cohort, retired: retired, answers: answers)
            }
        }
    }

    /// `stack`'s record of `token` in its own layout (first, so nothing the token's own calls cost can starve it), then the
    /// token's `name`, `symbol` and `getTokenInfo`.
    static func launchReads(_ token: Address, stack: LaunchpadAddresses) -> [ContractCall] {
        typealias T = LaunchpadABI.Token
        return [
            LaunchpadABI.call(stack.factory, LaunchpadABI.Factory.getLaunchedToken, [.address(token)], returns: LaunchpadABI.launchedTokenReturns(legacy: stack.generation.legacyRecord)),
            LaunchpadABI.call(token, T.name, returns: "string"),
            LaunchpadABI.call(token, T.symbol, returns: "string"),
            LaunchpadABI.call(token, T.getTokenInfo, returns: "address,string,string,\(LaunchpadABI.socialsTuple)"),
        ]
    }

    /// `cohort`'s `momentIdByCoin` of `moment`'s coin (first), then the coin's `name` and `symbol` and its NFT's
    /// `provenance`.
    static func momentReads(_ moment: Moment, cohort: MomentsAddresses) -> [ContractCall] {
        [
            MomentsABI.call(cohort.factory, MomentsABI.Factory.momentIdByCoin, [.address(moment.coin)], returns: "uint256"),
            MomentsABI.call(moment.coin, MomentsABI.Coin.name, returns: "string"),
            MomentsABI.call(moment.coin, MomentsABI.Coin.symbol, returns: "string"),
            MomentsABI.call(moment.nft, MomentsABI.NFT.provenance, returns: MomentsABI.provenanceTuple),
        ]
    }

    /// Pure: the coin `token` is on `stack`, from `launchReads`' answers — only when the stack's record of it exists, names
    /// this very token and a curve; nil otherwise, or when the record is missing. Its text is as read: a name or symbol
    /// that couldn't be read is `ChainText.unreadable`, a picture that couldn't be read none.
    static func launchCoin(_ token: Address, stack: LaunchpadAddresses, retired: Bool, answers: [Result<[ABIValue], Error>]) -> DyorCoin? {
        guard answers.count == 4, case .success(let record) = answers[0], let tuple = record.first else { return nil }
        let launch = LaunchpadABI.LaunchRecord(tuple, legacy: stack.generation.legacyRecord)
        guard launch.exists, launch.token == token, !launch.curve.isZero, !token.isZero else { return nil }
        var logo = ""
        if case .success(let info) = answers[3], info.count == 4 { logo = LaunchpadABI.TokenInfo(info).logo }
        return DyorCoin(address: token, origin: .launch(factory: stack.factory, generation: stack.generation, retired: retired),
                        symbol: text(answers[2]), name: text(answers[1]), creator: launch.deployer, logo: logo, pair: launch.pairToken)
    }

    /// Pure: `moment`'s coin on `cohort`, from `momentReads`' answers — only when the cohort maps the coin back to this
    /// Moment's id; nil otherwise, or when that answer is missing. Its text is as read, as `launchCoin`'s; provenance
    /// that couldn't be read leaves it with no picture.
    static func momentCoin(_ moment: Moment, cohort: MomentsAddresses, retired: Bool, answers: [Result<[ABIValue], Error>]) -> DyorCoin? {
        guard answers.count == 4, case .success(let idValues) = answers[0], let id = idValues.first?.uint,
              moment.id > 0, id == moment.id, !moment.coin.isZero, moment.factory == cohort.factory else { return nil }
        var provenance: MomentProvenance?
        if case .success(let values) = answers[3], let tuple = values.first { provenance = MomentsABI.provenance(tuple) }
        return DyorCoin(address: moment.coin, origin: .moment(factory: cohort.factory, id: moment.id, retired: retired),
                        symbol: text(answers[2]), name: text(answers[1]), creator: moment.creator,
                        logo: provenance?.mediaURI ?? "", mediaHash: provenance?.mediaHash, mediaIsVideo: !(provenance?.animationURI.isEmpty ?? true),
                        pair: cohort.usdc)
    }

    /// A `string` answer as read (bytes that aren't text already U+FFFD), or `ChainText.unreadable` when the call failed.
    private static func text(_ answer: Result<[ABIValue], Error>) -> String {
        guard case .success(let values) = answer, let value = values.first, case .string(let text) = value else { return ChainText.unreadable }
        return text
    }

    // MARK: Point proof

    /// What each of `addresses` is, reading the factories for those not known yet (MON and the curated tokens are never
    /// asked): see `Membership`. A coin proven here is kept like one enumerated.
    public func prove(_ addresses: [Address]) async -> [Address: Membership] {
        var out: [Address: Membership] = [:]
        var candidates: [Address] = []
        for address in addresses where out[address] == nil {
            let known = membership(address)
            out[address] = known
            if known == .unknown { candidates.append(address) }
        }
        guard !candidates.isEmpty, !launchpads.isEmpty || !cohorts.isEmpty else { return out }
        tasksStarted += 1
        let id = tasksStarted
        let task = Task { await self.proveReads(candidates) }
        proving[id] = task
        await task.value
        proving[id] = nil
        for address in candidates { out[address] = membership(address) }
        return out
    }

    /// `prove`'s reads for `candidates`, none known yet, and what they come to kept.
    private func proveReads(_ candidates: [Address]) async {
        let epoch = self.epoch
        // 1. Every factory's count. One whose count is its checkpoint has named every coin it has, and each is known here
        //    (the checkpoint only ever moves past a coin as it is kept): a candidate not known isn't one of them. The
        //    others — a count past the checkpoint, below it (a node behind), or unanswered — are asked.
        let sources = launchpads.map(Source.launchpad) + cohorts.map(Source.cohort)
        let counts = await read(sources.map(\.countCall))
        var asked: Set<Address> = []
        for (source, result) in zip(sources, counts) {
            if case .success(let values) = result, let value = values.first, LaunchpadABI.int(value) == checkpoints[source.factory] ?? 0 { continue }
            asked.insert(source.factory)
        }
        let launchpads = self.launchpads.filter { asked.contains($0.factory) }
        let cohorts = self.cohorts.filter { asked.contains($0.factory) }
        guard !launchpads.isEmpty || !cohorts.isEmpty else {
            guard epoch == self.epoch else { return }
            notDyor.formUnion(candidates.filter { coins[$0] == nil })
            return
        }
        // 2. Each of those launchpads' record of each candidate, in its own layout, and each of those cohorts' Moment id
        //    for it: the factories' own answers, of a fixed size.
        let perCandidate = launchpads.count + cohorts.count
        let records = await read(candidates.flatMap { candidate in
            launchpads.map { LaunchpadABI.call($0.factory, LaunchpadABI.Factory.getLaunchedToken, [.address(candidate)], returns: LaunchpadABI.launchedTokenReturns(legacy: $0.generation.legacyRecord)) }
                + cohorts.map { MomentsABI.call($0.factory, MomentsABI.Factory.momentIdByCoin, [.address(candidate)], returns: "uint256") }
        })
        let claims = candidates.enumerated().map { i, candidate in
            Self.claims(candidate, launchpads: launchpads, cohorts: cohorts, answers: Array(records[i * perCandidate..<(i + 1) * perCandidate]))
        }
        // 3. At once: each launch a factory named, read as enumeration reads it (its record again, then its text); and
        //    each Moment id a cohort gave, the Moment, to see whether it is this coin's.
        let launchClaims = claims.compactMap { claim in claim.launch.map { (address: claim.address, stack: $0) } }
        let momentClaims = claims.filter { $0.launch == nil && !$0.moments.isEmpty }
        async let launchAnswers = readItems(launchClaims.map { Self.launchReads($0.address, stack: $0.stack) })
        async let momentAnswers = read(momentClaims.flatMap { claim in claim.moments.map { MomentsABI.call($0.0.factory, MomentsABI.Factory.getMoment, [.uint($0.1)], returns: MomentsABI.momentTuple) } })
        var found: [DyorCoin] = []
        if let answers = await launchAnswers {
            for (claim, answer) in zip(launchClaims, answers) {
                if let coin = Self.launchCoin(claim.address, stack: claim.stack, retired: claim.stack.factory != liveLaunchpad, answers: answer) { found.append(coin) }
            }
        }
        let moments = await momentAnswers
        var confirmed: [(cohort: MomentsAddresses, moment: Moment)] = []
        var settled = Set(claims.filter { $0.launch == nil && $0.moments.isEmpty }.map(\.address))
        var cursor = 0
        for claim in momentClaims {
            var answered = true
            var match: (MomentsAddresses, Moment)?
            for (cohort, id) in claim.moments {
                let answer = moments[cursor]
                cursor += 1
                guard case .success(let values) = answer, let tuple = values.first else { answered = false; continue }
                let moment = MomentsABI.moment(id: id, tuple, factory: cohort.factory)
                if moment.coin == claim.address, match == nil { match = (cohort, moment) }
            }
            if let match { confirmed.append(match) } else if answered { settled.insert(claim.address) }
        }
        // 4. Each Moment that is this coin's, read as enumeration reads it.
        if let answers = await readItems(confirmed.map { Self.momentReads($0.moment, cohort: $0.cohort) }) {
            for (entry, answer) in zip(confirmed, answers) {
                if let coin = Self.momentCoin(entry.moment, cohort: entry.cohort, retired: entry.cohort.factory != liveCohort, answers: answer) { found.append(coin) }
            }
        }
        // A coin is DyorHQ's only on its factory's word; "not DyorHQ" only when every factory asked answered and none named
        // it (and every other one has named all its coins).
        let negatives = claims.filter { $0.launch == nil && $0.complete && settled.contains($0.address) }.map(\.address)
        guard epoch == self.epoch else { return }
        notDyor.formUnion(negatives)
        commit(found)
    }

    /// What the factories' first answers say of one candidate.
    struct Claims {
        let address: Address
        /// The launchpad whose record of it names it and a curve: the first (live first) whose record exists and names a
        /// curve (`LaunchpadService.firstRecord`, as `knownCurve` and held coins find one), when that record names it.
        let launch: LaunchpadAddresses?
        /// Each cohort that maps it to a Moment id, with the id.
        let moments: [(MomentsAddresses, BigUInt)]
        /// Every factory answered.
        let complete: Bool
    }

    /// Pure: `answers` holds each launchpad's `getLaunchedToken(candidate)` then each cohort's `momentIdByCoin(candidate)`.
    static func claims(_ candidate: Address, launchpads: [LaunchpadAddresses], cohorts: [MomentsAddresses], answers: [Result<[ABIValue], Error>]) -> Claims {
        var complete = answers.count == launchpads.count + cohorts.count
        let records = Array(answers.prefix(launchpads.count))
        for answer in records {
            guard case .success(let values) = answer, values.first != nil else { complete = false; continue }
        }
        let hit = LaunchpadService.firstRecord(stacks: launchpads, records: records)
        var moments: [(MomentsAddresses, BigUInt)] = []
        for (cohort, answer) in zip(cohorts, answers.dropFirst(launchpads.count)) {
            guard case .success(let values) = answer, let id = values.first?.uintOrNil else { complete = false; continue }
            if id > 0 { moments.append((cohort, id)) }
        }
        return Claims(address: candidate, launch: hit.flatMap { $0.record.token == candidate ? $0.stack : nil }, moments: moments, complete: complete)
    }

    // MARK: Ingest

    /// Launches another screen read (`LaunchpadService`: the board, Home's holdings, a launch that just settled). The coin
    /// of each launch of a launchpad the registry reads that isn't known yet is proven (`prove`): only its factory's own
    /// record admits it, never the `Launch` given, which anything could have built.
    @discardableResult
    public func ingest(_ launches: [Launch]) async -> [Address: Membership] {
        await prove(launches.filter { launch in
            let factory = launch.factory.isZero ? liveLaunchpad : launch.factory
            return !launch.token.isZero && !factory.isZero && launchpads.contains { $0.factory == factory }
        }.map(\.token))
    }

    /// Moments another screen read (`MomentsService`, `RetiredMoments`: the Moments tab, holdings, a publish that just
    /// settled). The coin of each Moment of a cohort the registry reads that isn't known yet is proven (`prove`), as
    /// `ingest(_ launches:)`.
    @discardableResult
    public func ingest(_ moments: [MomentInfo]) async -> [Address: Membership] {
        await prove(moments.filter { info in
            !info.moment.coin.isZero && info.moment.id > 0 && cohorts.contains { $0.factory == info.moment.factory }
        }.map(\.moment.coin))
    }

    // MARK: Erase

    /// Forgets everything and deletes the file (account deletion). A refresh or proof under way is cancelled and writes
    /// nothing back, and the next refresh reads the chain afresh rather than joining it.
    public func erase() {
        epoch += 1
        running?.task.cancel()
        running = nil
        for task in proving.values { task.cancel() }
        proving = [:]
        coins = [:]
        checkpoints = [:]
        notDyor = []
        lowerCounts = [:]
        lastCompleteRefresh = nil
        store?.erase()
        publish()
    }

    // MARK: Keeping

    /// Keeps `found` (an entry that differs replaces the old one; MON and the curated tokens never are one) after
    /// dropping every coin of the factories `dropping` names, then saves and tells the subscribers when anything
    /// changed.
    private func commit(_ found: [DyorCoin], dropping factories: Set<Address> = [], persistAnyway: Bool = false) {
        var changed = false
        if !factories.isEmpty {
            let kept = coins.filter { !factories.contains($0.value.factory) }
            changed = kept.count != coins.count
            coins = kept
        }
        for coin in found where !coin.address.isZero && Token.core(coin.address) == nil && coins[coin.address] != coin {
            coins[coin.address] = coin
            notDyor.remove(coin.address)
            changed = true
        }
        if changed || persistAnyway {
            try? store?.save(DyorCoinStore.Snapshot(coins: Array(coins.values), checkpoints: checkpoints.map { DyorCoinStore.Checkpoint(factory: $0.key, count: $0.value) }))
        }
        if changed { publish() }
    }

    private func publish() {
        for subscriber in subscribers.values { subscriber.yield(coins) }
    }

    /// Pure: what of `snapshot` the registry keeps — the coins and counts of the factories it reads, each coin's generation
    /// and retired flag as this build's tables say (a stack or cohort retired since the file was written reads as retired).
    static func restored(_ snapshot: DyorCoinStore.Snapshot, launchpads: [LaunchpadAddresses], cohorts: [MomentsAddresses],
                         liveLaunchpad: Address, liveCohort: Address) -> (coins: [Address: DyorCoin], checkpoints: [Address: Int]) {
        var coins: [Address: DyorCoin] = [:]
        for coin in snapshot.coins where !coin.address.isZero && Token.core(coin.address) == nil {
            switch coin.origin {
            case .launch(let factory, _, _):
                guard let stack = launchpads.first(where: { $0.factory == factory }) else { continue }
                coins[coin.address] = DyorCoin(address: coin.address, origin: .launch(factory: factory, generation: stack.generation, retired: factory != liveLaunchpad),
                                               symbol: coin.symbol, name: coin.name, creator: coin.creator, logo: coin.logo, pair: coin.pair)
            case .moment(let factory, let id, _):
                guard cohorts.contains(where: { $0.factory == factory }) else { continue }
                coins[coin.address] = DyorCoin(address: coin.address, origin: .moment(factory: factory, id: id, retired: factory != liveCohort),
                                               symbol: coin.symbol, name: coin.name, creator: coin.creator, logo: coin.logo,
                                               mediaHash: coin.mediaHash, mediaIsVideo: coin.mediaIsVideo, pair: coin.pair)
            }
        }
        let factories = Set(launchpads.map(\.factory) + cohorts.map(\.factory))
        var checkpoints: [Address: Int] = [:]
        for checkpoint in snapshot.checkpoints where factories.contains(checkpoint.factory) && checkpoint.count > 0 { checkpoints[checkpoint.factory] = checkpoint.count }
        return (coins, checkpoints)
    }

    // MARK: Reading

    /// `calls` in Multicall3 reads of at most `maxCallsPerRead`, `Multicall.readsInFlight` of them at a time (the next as
    /// each answers), their answers in `calls` order; every call of a read that failed as a whole comes back as a
    /// failure. For the factories' own answers, which are of a fixed size.
    private func read(_ calls: [ContractCall]) async -> [Result<[ABIValue], Error>] {
        let chunks = stride(from: 0, to: calls.count, by: Self.maxCallsPerRead).map { Array(calls[$0 ..< min(calls.count, $0 + Self.maxCallsPerRead)]) }
        var answers = [[Result<[ABIValue], Error>]](repeating: [], count: chunks.count)
        let multicall = multicall
        await withTaskGroup(of: (Int, [Result<[ABIValue], Error>]).self) { group in
            var next = 0
            func send() {
                guard next < chunks.count else { return }
                let index = next
                next += 1
                let chunk = chunks[index]
                group.addTask {
                    do {
                        let results = try await multicall.read(chunk)
                        return (index, results.count == chunk.count ? results : chunk.map { _ in .failure(NetworkError.malformedResponse) })
                    } catch {
                        return (index, chunk.map { _ in .failure(error) })
                    }
                }
            }
            for _ in 0 ..< Multicall.readsInFlight { send() }
            while let (index, results) = await group.next() {
                answers[index] = results
                send()
            }
        }
        return answers.flatMap { $0 }
    }

    /// Coins' reads (`launchReads`, `momentReads`) as a list's items (`Multicall.readItems`); nil when a record couldn't
    /// be read or no answer came.
    private func readItems(_ items: [[ContractCall]]) async -> [[Result<[ABIValue], Error>]]? {
        guard !items.isEmpty else { return [] }
        return try? await multicall.readItems(items, text: Self.textCalls, what: .dyorCoin)
    }
}
