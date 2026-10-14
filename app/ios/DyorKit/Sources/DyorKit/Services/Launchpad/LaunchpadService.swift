import BigInt
import Foundation

/// The launchpad client: every read comes straight from the contracts through Multicall3, and every write is
/// a `TransactionStep` plan for `TransactionSender`. A port of the web app's `launchpad.ts` / `actions.ts`;
/// the derivations (price, market cap, progress) are identical so both apps agree to the wei.
public actor LaunchpadService {
    /// Where `eth_getLogs` goes on mainnet: rpc1.monad.xyz allows 1 000 blocks per request against 100 on rpc.monad.xyz.
    public static let defaultLogsRPC = URL(string: "https://rpc1.monad.xyz")!
    /// `LaunchpadFactory.MAX_EXEMPTIONS`.
    public static let maxExemptions = 32
    /// Blocks added to a coin's age in blocks when the block it launched in is estimated (`launchBlock`), so the launch
    /// itself is inside the window its fills and its holders are read from. (A coin's holders were read over a fixed
    /// 6,480,000 blocks, `holderScanBlocks`, until build 23: they are read from its launch now, `holders`.)
    public static let tradeLookbackMargin: UInt64 = 20_000

    public let rpc: RPCClient
    /// The endpoint used for event history; a local fork keeps logs on the same node.
    public let logsRPC: RPCClient
    public private(set) var addresses: LaunchpadAddresses
    /// Turns block numbers into the times the history shows, and a day or a coin's age into blocks.
    public let clock: BlockClock
    let multicall: Multicall
    private var pairCache: [Address: PairInfo] = [:]
    /// The reads the app's screens share (`ChainCache`): the launch list is read once for every screen that asks within
    /// its time (`launchListing`). Nil reads it every time, as a test does.
    let cache: ChainCache?
    /// Where each settled launch's fixed facts are kept between launches (`LaunchStatics`), so a refresh of the shared
    /// list reads only what moves. Nil reads them every time.
    let store: ChainStore?
    /// The device clock: which launches are settled enough to keep (`ChainSettled`).
    private let now: @Sendable () -> Date
    /// What `store` keeps, by factory and index in its list, as of `staticsEpoch` (nil until read).
    private var statics: [Address: [Int: LaunchStatics]] = [:]
    private var staticsEpoch: Int?

    public init(rpc: RPCClient, addresses: LaunchpadAddresses, logsRPC: RPCClient? = nil, clock: BlockClock? = nil,
                cache: ChainCache? = nil, store: ChainStore? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rpc = rpc
        self.addresses = addresses
        let text = rpc.url.absoluteString
        let local = text.contains("127.0.0.1") || text.contains("localhost")
        self.logsRPC = logsRPC ?? (local ? rpc : RPCClient(url: Self.defaultLogsRPC))
        self.clock = clock ?? BlockClock(rpc: rpc)
        multicall = Multicall(rpc: rpc)
        self.cache = cache
        self.store = store
        self.now = now
    }

    /// Swaps in the deployed addresses once they are known. Cached pair metadata survives; it is chain data.
    public func setAddresses(_ addresses: LaunchpadAddresses) {
        self.addresses = addresses
    }

    public var isDeployed: Bool { addresses.isDeployed }

    /// The live stack followed by every retired one (skipping a retired stack the build is configured to as live). A
    /// live stack that is not deployed yet (v2 pending) is left out, so the list is the retired stacks alone and
    /// nothing is ever read from address 0.
    public var stacks: [LaunchpadAddresses] {
        (addresses.isDeployed ? [addresses] : []) + retiredStacks
    }

    /// Every retired stack, newest first; they keep serving their launches whether or not the live one is deployed.
    public var retiredStacks: [LaunchpadAddresses] {
        LaunchpadAddresses.retiredStacks.filter { $0.factory != addresses.factory }
    }

    /// The stack whose factory is `factory`: the live one (also for `.zero`), a retired one, or — for a factory the
    /// app does not know — that factory alone, so no per-launch call is ever sent to another stack's modules.
    public func stack(for factory: Address) -> LaunchpadAddresses {
        if factory.isZero || factory == addresses.factory { return addresses }
        return LaunchpadAddresses.retiredStack(for: factory) ?? LaunchpadAddresses(factory: factory, poolManager: addresses.poolManager)
    }

    /// The stack that recorded `launch`; every per-launch read and write goes to it.
    public func stack(for launch: Launch) -> LaunchpadAddresses { stack(for: launch.factory) }

    // MARK: - Pair assets

    /// Symbol and decimals of a pair asset; native MON needs no read. Cached for the life of the service.
    public func pairInfo(_ address: Address) async throws -> PairInfo {
        try await pairInfos([address])[address] ?? .mon
    }

    private func pairInfos(_ tokens: [Address]) async throws -> [Address: PairInfo] {
        var out: [Address: PairInfo] = [:]
        var missing: [Address] = []
        for token in Set(tokens) {
            if token.isZero {
                out[token] = .mon
            } else if let cached = pairCache[token] {
                out[token] = cached
            } else {
                missing.append(token)
            }
        }
        guard !missing.isEmpty else { return out }
        missing.sort { $0.hex < $1.hex }
        let calls = missing.flatMap { [LaunchpadABI.call($0, LaunchpadABI.Token.symbol, returns: "string"), LaunchpadABI.call($0, LaunchpadABI.Token.decimals, returns: "uint8")] }
        let results = try await multicall.readAll(calls)
        for (i, token) in missing.enumerated() {
            let info = PairInfo(address: token, symbol: results[2 * i][0].string, decimals: LaunchpadABI.int(results[2 * i + 1][0]), isNative: false)
            pairCache[token] = info
            out[token] = info
        }
        return out
    }

    // MARK: - Reads

    /// Factory policy, launch template 0 and the economics of native MON plus `extraPairTokens` (the ERC-20
    /// pairs the owner approved), and what decides whether Launch is offered (`ProtocolInfo.launchBlocker`): on v2 the
    /// sealed flag and the module wiring, and `canLaunch(account)` when an account is given. Nil until the contracts
    /// are deployed.
    public func protocolInfo(extraPairTokens: [Address] = [], account: Address? = nil) async throws -> ProtocolInfo? {
        guard addresses.isDeployed else { return nil }
        let factory = addresses.factory
        typealias F = LaunchpadABI.Factory
        let checksModules = addresses.generation.hasV2Getters
        let policy = try await multicall.readAll([
            LaunchpadABI.call(factory, F.launchFee, returns: "uint256"),
            LaunchpadABI.call(factory, F.launchConfigCount, returns: "uint256"),
            LaunchpadABI.call(factory, F.maxCreatorTaxBps, returns: "uint16"),
            LaunchpadABI.call(factory, F.whitelistEnabled, returns: "bool"),
            LaunchpadABI.call(factory, F.getLaunchFeePolicy, returns: "(address,uint16)"),
            LaunchpadABI.call(factory, F.launchCount, returns: "uint256"),
        ] + (checksModules ? moduleCalls(factory) : []) + (account.map { [LaunchpadABI.call(factory, F.canLaunch, [.address($0)], returns: "bool")] } ?? []))
        var index = 6
        func next() -> [ABIValue] {
            defer { index += 1 }
            return policy[index]
        }
        let wiring = checksModules ? Self.wiring(sealed: next(), modules: (0..<8).map { _ in next() }) : nil
        let accountCanLaunch = account == nil ? nil : next()[0].bool
        let configId: BigUInt = 0
        let hasConfig = policy[1][0].uint > 0
        let pairTokens = [Address.zero] + extraPairTokens
        let configCalls: [ContractCall] = hasConfig ? [LaunchpadABI.call(factory, F.getLaunchConfig, [.uint(configId)], returns: LaunchpadABI.launchConfigTuple)] : []
        // Economics and the Monday-only flag are read for every pair: the create screen uses `mondayOnly` to force
        // the Monday graduation venue (and disable the picker) for aBIL, matching the factory's `PairRequiresMonday`.
        let econCalls = pairTokens.map { LaunchpadABI.call(factory, F.pairTokenEconomics, [.address($0)], returns: "uint256,uint256,uint8,bool") }
        let mondayOnlyCalls = pairTokens.map { LaunchpadABI.call(factory, F.pairMondayOnly, [.address($0)], returns: "bool") }
        // The terms hash for each pair, in the same multicall (one block) as the terms the screen shows, so a launch
        // can be bound to exactly what was shown (IOST-2).
        let hashCalls = pairTokens.map { LaunchpadABI.call(factory, F.previewLaunchEconomics, [.uint(configId), .address($0)], returns: "bytes32") }
        let calls = configCalls + econCalls + mondayOnlyCalls + hashCalls
        async let economics = multicall.readAll(calls)
        async let infos = pairInfos(pairTokens)
        let (results, pairs) = try await (economics, infos)
        let config = hasConfig ? LaunchpadABI.LaunchConfig(results[0][0]) : nil
        let offset = hasConfig ? 1 : 0
        let mondayOffset = offset + pairTokens.count
        let hashOffset = mondayOffset + pairTokens.count
        let pairEconomics = pairTokens.enumerated().map { i, token in
            let values = results[offset + i]
            let mondayOnly = results[mondayOffset + i][0].bool
            return PairEconomics(pair: pairs[token] ?? .mon, phantomQuote: values[0].uint, graduationThreshold: values[1].uint, approved: values[3].bool,
                                 mondayOnly: mondayOnly, economicsHash: results[hashOffset + i][0].bytes)
        }
        return ProtocolInfo(
            launchFee: policy[0][0].uint,
            configId: configId,
            supply: config?.supply ?? 0,
            curveFeeBps: config?.curveFeeBps ?? 0,
            poolFeeBps: config?.poolFeeBps ?? 0,
            snipeSchedule: config?.snipeTaxSchedule ?? [],
            configEnabled: config?.enabled ?? false,
            maxCreatorTaxBps: LaunchpadABI.int(policy[2][0]),
            whitelistEnabled: policy[3][0].bool,
            protocolFeeShareBps: LaunchpadABI.int(policy[4][0][1]),
            launchCount: LaunchpadABI.int(policy[5][0]),
            pairs: pairEconomics,
            modulesSealed: wiring?.sealed,
            moduleMismatches: wiring?.modules.mismatches(addresses) ?? [],
            accountCanLaunch: accountCanLaunch
        )
    }

    /// `modulesSealed()` and the eight module getters, in `wiring(sealed:modules:)`'s order. v2 only.
    private func moduleCalls(_ factory: Address) -> [ContractCall] {
        typealias F = LaunchpadABI.Factory
        return [LaunchpadABI.call(factory, F.modulesSealed, returns: "bool")]
            + [F.hook, F.router, F.escrow, F.holderFeeSharing, F.locker, F.graduationExecutor, F.mondayExecutor, F.launchDeployer].map { LaunchpadABI.call(factory, $0, returns: "address") }
    }

    private static func wiring(sealed: [ABIValue], modules m: [[ABIValue]]) -> (sealed: Bool, modules: LaunchpadModules) {
        (sealed[0].bool, LaunchpadModules(hook: m[0][0].address, router: m[1][0].address, escrow: m[2][0].address, holderFeeSharing: m[3][0].address,
                                          locker: m[4][0].address, graduationExecutor: m[5][0].address, mondayExecutor: m[6][0].address, launchDeployer: m[7][0].address))
    }

    /// Whether the factory would refuse `account`'s launch with template `configId` right now (`LaunchBlocker`), read
    /// fresh: v2's sealed flag and module wiring, the template's switch and the whitelist.
    public func launchBlocker(account: Address, configId: BigUInt = 0) async throws -> LaunchBlocker? {
        guard addresses.isDeployed else { throw LaunchpadError.notDeployed }
        let factory = addresses.factory
        typealias F = LaunchpadABI.Factory
        let checksModules = addresses.generation.hasV2Getters
        // Tolerant read: a template id past the end reverts, which means "no such template".
        let r = try await multicall.read([
            LaunchpadABI.call(factory, F.whitelistEnabled, returns: "bool"),
            LaunchpadABI.call(factory, F.canLaunch, [.address(account)], returns: "bool"),
            LaunchpadABI.call(factory, F.getLaunchConfig, [.uint(configId)], returns: LaunchpadABI.launchConfigTuple),
        ] + (checksModules ? moduleCalls(factory) : []))
        func value(_ i: Int) throws -> [ABIValue] { try r[i].get() }
        let config = try? value(2)
        let wiring = checksModules ? Self.wiring(sealed: try value(3), modules: try (4..<12).map(value)) : nil
        return LaunchBlocker.check(modulesSealed: wiring?.sealed, moduleMismatches: wiring?.modules.mismatches(addresses) ?? [],
                                   configEnabled: config.map { LaunchpadABI.LaunchConfig($0[0]).enabled } ?? false,
                                   whitelistEnabled: try value(0)[0].bool, accountCanLaunch: try value(1)[0].bool)
    }

    /// The newest `limit` launches, newest first. Empty until the contracts are deployed.
    public func launches(limit: Int = 48) async throws -> [Launch] {
        guard addresses.isDeployed else { return [] }
        return try await launches(limit: limit, factory: addresses.factory)
    }

    /// Launches recorded by a specific factory — the live one or a retired one whose history still counts. Every coin the
    /// factory lists is on the page: one whose text can't be read shows stand-ins (`hydrate`), and a read that doesn't
    /// answer for every coin throws (`ChainListUnread`), never a shorter list. The records hold no text, so they are read
    /// all or nothing: a listed coin whose record is missing or empty, like a page shorter than the count, was read on a
    /// node behind the one that listed it.
    public func launches(limit: Int = 48, factory: Address) async throws -> [Launch] {
        guard !factory.isZero, limit > 0 else { return [] }
        let legacy = stack(for: factory).generation.legacyRecord
        let total = LaunchpadABI.int(try await multicall.readAll([LaunchpadABI.call(factory, LaunchpadABI.Factory.launchCount, returns: "uint256")])[0][0])
        guard total > 0 else { return [] }
        let offset = max(0, total - limit)
        let page = try await multicall.readAll([LaunchpadABI.call(factory, LaunchpadABI.Factory.getLaunches, [.uint(offset), .uint(total - offset)], returns: "address[]")])[0][0].elements.map(\.address)
        // A page shorter than the count (an empty one included) was read on a node behind the one that counted: the shared
        // list's read refuses it too (`launches(limit:factory:total:epoch:)`).
        guard page.count == total - offset else { throw ChainListUnread(.launch) }
        let records = try await multicall.readAll(page.map { LaunchpadABI.call(factory, LaunchpadABI.Factory.getLaunchedToken, [.address($0)], returns: LaunchpadABI.launchedTokenReturns(legacy: legacy)) })
            .map { LaunchpadABI.LaunchRecord($0[0], legacy: legacy) }
        for (token, record) in zip(page, records) where !record.exists || record.token != token { throw ChainListUnread(.launch) }
        return try await hydrate(records, factory: factory).reversed()
    }

    /// The newest `limit` launches of the live factory followed by those of each retired factory (newest stack first),
    /// so the whole list stays newest first, with every factory whose launches couldn't be read (`LaunchListing.unread`):
    /// one factory's failure never takes the others down, and is never mistaken for a factory with fewer launches. While
    /// the live stack is not deployed (v2 pending) the list is the retired stacks' launches alone.
    ///
    /// With the app's shared reads (`cache`), every screen's list comes from one read of `listingLimit` launches per
    /// factory (`sharedListing`), each screen taking its own newest `limit` (`LaunchListing.prefix(perFactory:)`): Home,
    /// the Portfolio, the board, My Launchpad and Recent Activity asking within `ChainCache.TTL.listing` share it, and
    /// a screen asking while it is read waits for it. A list that couldn't be read in full is never kept, so a Retry
    /// reads again at once.
    ///
    /// A factory the shared read couldn't read (its `listingLimit` launches: a page, a record or a curve that didn't
    /// answer, a cold device keeping none of them) is read again for a screen listing fewer, with that screen's own
    /// `limit` (`factoryLaunches`): Home's 30 and the board's 60 are never unread for want of the Portfolio's 200, and are
    /// exactly what a read of `limit` lists. Screens asking for the same `limit` at once share that read too.
    public func launchListing(limit: Int = 48) async -> LaunchListing {
        guard let cache, limit > 0, limit <= Self.listingLimit else { return await readListing(limit: limit) }
        let key = "launchpad.listing." + stacks.map(\.factory.hex).joined(separator: ",")
        // `sharedListing` can't fail (a factory's failure is in the listing), so neither can this read.
        guard let shared = try? await cache.value(key, ttl: ChainCache.TTL.listing, keep: { (listing: LaunchListing) in listing.complete },
                                                  read: { await self.sharedListing() }) else { return await readListing(limit: limit) }
        let listing = shared.prefix(perFactory: limit)
        guard limit < Self.listingLimit, !listing.unread.isEmpty else { return listing }
        let unread = listing.factories.filter { listing.unread[$0] != nil }
        let reads = await withTaskGroup(of: (Address, Result<[Launch], Error>).self) { group in
            for factory in unread {
                group.addTask {
                    (factory, await ERC20.captured {
                        try await cache.value("launchpad.factory.\(factory.hex).\(limit)", ttl: ChainCache.TTL.listing) { try await self.factoryLaunches(limit: limit, factory: factory) }
                    })
                }
            }
            var out: [Address: Result<[Launch], Error>] = [:]
            for await (factory, read) in group { out[factory] = read }
            return out
        }
        return Self.listing(factories: listing.factories, reads: listing.factories.map { factory in
            reads[factory] ?? .success(listing.launches.filter { $0.factory == factory })
        })
    }

    /// One factory's newest `limit` launches for a screen the shared read failed it for (`launchListing`): its count, then
    /// its launches as the shared read reads them (`launches(limit:factory:total:epoch:)`), those the device keeps for what
    /// moves only.
    private func factoryLaunches(limit: Int, factory: Address) async throws -> [Launch] {
        let epoch = store?.epoch
        let total = LaunchpadABI.int(try await multicall.readAll([LaunchpadABI.call(factory, LaunchpadABI.Factory.launchCount, returns: "uint256")])[0][0])
        return try await launches(limit: limit, factory: factory, total: total, epoch: epoch)
    }

    /// The most launches of each factory a screen lists (the Portfolio's 200): what the shared list reads
    /// (`launchListing`), every screen taking its own newest from it.
    public static let listingLimit = 200

    /// `launchListing` read now, factory by factory, each in full.
    private func readListing(limit: Int) async -> LaunchListing {
        let factories = stacks.map(\.factory)
        let reads = await withTaskGroup(of: (Int, Result<[Launch], Error>).self) { group in
            for (i, factory) in factories.enumerated() {
                group.addTask { (i, await ERC20.captured { try await self.launches(limit: limit, factory: factory) }) }
            }
            var out = Array(repeating: Result<[Launch], Error>.success([]), count: factories.count)
            for await (i, read) in group { out[i] = read }
            return out
        }
        return Self.listing(factories: factories, reads: reads)
    }

    /// The list every screen shares (`launchListing`): the newest `listingLimit` launches of every factory, all their
    /// counts in one read (`launchCounts`), then each factory's launches (`launches(limit:factory:total:epoch:)`): a launch
    /// kept on the device has only what moves read again — its record, its curve's price, reserves and state, and its
    /// pool's price once graduated — and any other is read in full. Factories are read side by side, and one that can't be
    /// read is named in the listing, as `readListing` names it.
    private func sharedListing() async -> LaunchListing {
        let factories = stacks.map(\.factory)
        let epoch = store?.epoch
        let counts = await launchCounts(factories)
        let reads = await withTaskGroup(of: (Int, Result<[Launch], Error>).self) { group in
            for (i, factory) in factories.enumerated() {
                let count = counts[i]
                group.addTask { (i, await ERC20.captured { try await self.launches(limit: Self.listingLimit, factory: factory, total: try count.get(), epoch: epoch) }) }
            }
            var out = Array(repeating: Result<[Launch], Error>.success([]), count: factories.count)
            for await (i, read) in group { out[i] = read }
            return out
        }
        return Self.listing(factories: factories, reads: reads)
    }

    /// The listing of `factories` from each one's read, in order: its launches, or its error (`LaunchListing.unread`).
    private static func listing(factories: [Address], reads: [Result<[Launch], Error>]) -> LaunchListing {
        var launches: [Launch] = []
        var unread: [Address: any Error] = [:]
        for (factory, read) in zip(factories, reads) {
            switch read {
            case .success(let list): launches += list
            case .failure(let error): unread[factory] = error
            }
        }
        return LaunchListing(factories: factories, launches: launches, unread: unread)
    }

    /// Every factory's `launchCount()` in one aggregate, each answer or failure in `factories`' order. An aggregate the
    /// node refuses as a whole (an `eth_call` error about the call itself: out of gas, a revert) is asked again factory
    /// by factory, side by side, so one factory can't take the others' counts down; any other failure (no answer,
    /// throttling) is every factory's, as it would be one by one.
    func launchCounts(_ factories: [Address]) async -> [Result<Int, Error>] {
        guard !factories.isEmpty else { return [] }
        let calls = factories.map { LaunchpadABI.call($0, LaunchpadABI.Factory.launchCount, returns: "uint256") }
        do {
            return try await multicall.read(calls).map { result in result.map { LaunchpadABI.int($0[0]) } }
        } catch where ERC20.isCallError(error) {
            let multicall = multicall
            return await withTaskGroup(of: (Int, Result<Int, Error>).self) { group in
                for (i, call) in calls.enumerated() {
                    group.addTask { (i, await ERC20.captured { LaunchpadABI.int(try await multicall.readAll([call])[0][0]) }) }
                }
                var out = Array(repeating: Result<Int, Error>.failure(ChainListUnread(.launch)), count: calls.count)
                for await (i, read) in group { out[i] = read }
                return out
            }
        } catch {
            return factories.map { _ in .failure(error) }
        }
    }

    /// One factory's newest `limit` launches of the `total` it lists (its count, read with every factory's), newest first,
    /// for the shared list: each launch the device keeps (`LaunchStatics`) has only what moves read (`hydrateKnown`), side
    /// by side with the full read of any other — its token from the factory's list, its record, then its text and curve
    /// (`hydrate`) — which is kept once the launch settled with its text read whole (`ChainSettled`). A list answered
    /// shorter than the count, or a listed coin with no record, was read on a node behind, and throws (`ChainListUnread`),
    /// never a shorter list. `epoch` is the store's when the listing began: nothing is kept after an erase.
    private func launches(limit: Int, factory: Address, total: Int, epoch: Int?) async throws -> [Launch] {
        guard !factory.isZero, limit > 0, total > 0 else { return [] }
        let legacy = stack(for: factory).generation.legacyRecord
        let window = max(0, total - limit) ..< total
        let saved = savedStatics(of: factory)
        async let knownRead = hydrateKnown(window.compactMap { saved[$0] }, factory: factory)
        var fresh: [(index: Int, launch: Launch)] = []
        if let first = window.first(where: { saved[$0] == nil }) {
            let page = try await multicall.readAll([LaunchpadABI.call(factory, LaunchpadABI.Factory.getLaunches, [.uint(first), .uint(total - first)], returns: "address[]")])[0][0].elements.map(\.address)
            guard page.count == total - first else { throw ChainListUnread(.launch) }
            let indices = (first ..< total).filter { saved[$0] == nil }
            let tokens = indices.map { page[$0 - first] }
            let records = try await multicall.readAll(tokens.map { LaunchpadABI.call(factory, LaunchpadABI.Factory.getLaunchedToken, [.address($0)], returns: LaunchpadABI.launchedTokenReturns(legacy: legacy)) })
                .map { LaunchpadABI.LaunchRecord($0[0], legacy: legacy) }
            for (token, record) in zip(tokens, records) where !record.exists || record.token != token { throw ChainListUnread(.launch) }
            let read = try await hydrateReading(records, factory: factory)
            var settled: [LaunchStatics] = []
            for (index, (record, entry)) in zip(indices, zip(records, read)) {
                fresh.append((index, entry.launch))
                if let text = entry.text, ChainSettled.isSettled(entry.launch.launchedAt, now: now()),
                   ChainSettled.isKeepable([text.name, text.symbol, text.logo, text.description, text.socials.twitter, text.socials.telegram,
                                            text.socials.discord, text.socials.website, text.socials.farcaster]) {
                    settled.append(LaunchStatics(factory: factory, index: index, record: record, text: text, launchedAt: entry.launch.launchedAt, supply: entry.launch.supply))
                }
            }
            if let epoch { keepStatics(settled, readSince: epoch) }
        }
        let all = try await knownRead + fresh
        return all.sorted { $0.index > $1.index }.map(\.launch)
    }

    /// Every factory's launches (`launchListing`), or the error of the first factory (the live one first) whose launches
    /// couldn't be read: for a reader that must have them all, such as one that totals what they are worth.
    public func allLaunches(limit: Int = 48) async throws -> [Launch] {
        let listing = await launchListing(limit: limit)
        if let error = listing.firstError { throw error }
        return listing.launches
    }

    /// One launch with its curve state, or nil when `token` was not launched on `factory` (the live factory when
    /// nil) or that stack is not deployed. A launch that is recorded but can't be read throws (`hydrate`): its page says
    /// so, with Retry, never "not found". Every read goes to that factory's own stack.
    public func launch(token: Address, factory: Address? = nil) async throws -> LaunchDetail? {
        let stack = stack(for: factory ?? addresses.factory)
        guard stack.isDeployed else { return nil }
        let factory = stack.factory
        typealias F = LaunchpadABI.Factory
        typealias C = LaunchpadABI.Curve
        let legacy = stack.generation.legacyRecord
        let tuple = try await multicall.readAll([LaunchpadABI.call(factory, F.getLaunchedToken, [.address(token)], returns: LaunchpadABI.launchedTokenReturns(legacy: legacy))])[0][0]
        let record = LaunchpadABI.LaunchRecord(tuple, legacy: legacy)
        guard record.exists else { return nil }
        let info = try await hydrate([record], factory: factory)[0]
        let curve = record.curve
        // Like the web app, "graduated" here includes refund mode: the pool key is reported for both.
        let graduated = record.phase.rawValue >= LaunchPhase.graduated.rawValue
        var calls: [ContractCall] = [
            LaunchpadABI.call(curve, C.feeBps, returns: "uint16"),
            LaunchpadABI.call(curve, C.snipeTaxSchedule, returns: "uint16[]"),
            LaunchpadABI.call(curve, C.getReserves, returns: "uint256,uint256"),
            LaunchpadABI.call(curve, C.sellableTokens, returns: "uint256"),
            LaunchpadABI.call(curve, C.phantomQuote, returns: "uint256"),
            LaunchpadABI.call(curve, C.reservedTokens, returns: "uint256"),
            LaunchpadABI.call(curve, C.swept, returns: "bool"),
            LaunchpadABI.call(factory, F.stuckSince, [.address(token)], returns: "uint256"),
            LaunchpadABI.call(factory, F.poolKeyOf, [.address(token)], returns: LaunchpadABI.poolKeyTuple),
        ]
        let readsHook = graduated && !stack.hook.isZero
        if readsHook {
            calls.append(LaunchpadABI.call(stack.hook, LaunchpadABI.Hook.pendingFees, [.bytes(record.poolId), .address(record.pairToken)], returns: "uint256"))
            calls.append(LaunchpadABI.call(stack.hook, LaunchpadABI.Hook.pendingCreatorTax, [.bytes(record.poolId), .address(record.pairToken)], returns: "uint256"))
        }
        // v2 hooks keep DyorHQ's cut apart once the holders' cut is forwarded in the swap. A v1 hook has no such getter:
        // the call reverts and would fail the whole read.
        let readsProtocolFees = readsHook && stack.generation.hasV2Getters
        if readsProtocolFees {
            calls.append(LaunchpadABI.call(stack.hook, LaunchpadABI.Hook.pendingProtocolFees, [.bytes(record.poolId), .address(record.pairToken)], returns: "uint256"))
        }
        // The pre-audit sharing contracts have no `queuedRewards`; the call reverts and would fail the whole read.
        let readsQueue = info.holderFeeSharing && !stack.holderFeeSharing.isZero && stack.generation.hasQueuedRewards
        if readsQueue {
            calls.append(LaunchpadABI.call(stack.holderFeeSharing, LaunchpadABI.Sharing.queuedRewards, [.address(token)], returns: "uint256,uint256"))
        }
        // v2, a Monday launch whose curve completed but that hasn't graduated (stuck): its fallback rule, from the
        // launch-time Monday-only snapshot, the owner's allowance and the delay (the first and last exist on v2 only).
        let readsFallback = stack.generation.hasV2Getters && record.graduationVenue == .monday && record.phase == .bonding && info.completed && !info.rescued
        if readsFallback {
            calls += [
                LaunchpadABI.call(factory, F.launchMondayOnly, [.address(token)], returns: "bool"),
                LaunchpadABI.call(factory, F.v4FallbackAllowed, [.address(token)], returns: "bool"),
                LaunchpadABI.call(factory, F.mondayOnlyFallbackDelay, returns: "uint256"),
            ]
        }
        let r = try await multicall.readAll(calls)
        var index = 9
        func next() -> [ABIValue] {
            defer { index += 1 }
            return r[index]
        }
        let pendingFees = readsHook ? next()[0].uint : 0
        let pendingTax = readsHook ? next()[0].uint : 0
        let protocolFees = readsProtocolFees ? next()[0].uint : 0
        let queued = readsQueue ? next()[0].uint : 0
        let rule = readsFallback ? GraduationFallbackRule(mondayOnly: next()[0].bool, allowed: next()[0].bool, delay: LaunchpadABI.int(next()[0])) : nil
        return LaunchDetail(
            launch: info,
            feeBps: LaunchpadABI.int(r[0][0]),
            snipeSchedule: r[1][0].elements.map(LaunchpadABI.int),
            quoteReserve: r[2][0].uint,
            tokenReserve: r[2][1].uint,
            sellableTokens: r[3][0].uint,
            phantomQuote: r[4][0].uint,
            reservedTokens: r[5][0].uint,
            swept: r[6][0].bool,
            stuckSince: LaunchpadABI.int(r[7][0]),
            poolKey: graduated ? LaunchpadABI.poolKey(r[8][0]) : nil,
            hookPendingFees: pendingFees,
            hookPendingTax: pendingTax,
            queuedRewards: queued,
            hookPendingProtocolFees: protocolFees,
            fallbackRule: rule
        )
    }

    /// Balances, allowance, snipe-tax status and claimables of `account` for one launch, in one round trip. Rewards
    /// and escrow come from the launch's own stack.
    public func accountView(_ launch: Launch, account: Address) async throws -> LaunchAccountView {
        let native = launch.pair.isNative
        let stack = stack(for: launch)
        var calls: [ContractCall] = [
            LaunchpadABI.call(launch.token, LaunchpadABI.Token.balanceOf, [.address(account)], returns: "uint256"),
            LaunchpadABI.call(launch.curve, LaunchpadABI.Curve.currentSnipeTaxBps, [.address(account)], returns: "uint256"),
            native
                ? LaunchpadABI.call(Multicall.address, LaunchpadABI.Multicall3.getEthBalance, [.address(account)], returns: "uint256")
                : LaunchpadABI.call(launch.pairToken, LaunchpadABI.Token.balanceOf, [.address(account)], returns: "uint256"),
        ]
        let readsAllowance = !native
        if readsAllowance { calls.append(LaunchpadABI.call(launch.pairToken, LaunchpadABI.Token.allowance, [.address(account), .address(launch.curve)], returns: "uint256")) }
        let readsRewards = launch.holderFeeSharing && !stack.holderFeeSharing.isZero
        if readsRewards { calls.append(LaunchpadABI.call(stack.holderFeeSharing, LaunchpadABI.Sharing.pendingRewards, [.address(launch.token), .address(account)], returns: "uint256")) }
        let readsEscrow = !stack.escrow.isZero
        if readsEscrow {
            calls.append(native
                ? LaunchpadABI.call(stack.escrow, LaunchpadABI.Escrow.balanceOf, [.address(account)], returns: "uint256")
                : LaunchpadABI.call(stack.escrow, LaunchpadABI.Escrow.balanceOfToken, [.address(account), .address(launch.pairToken)], returns: "uint256"))
        }
        let r = try await multicall.readAll(calls)
        var index = 3
        func next() -> BigUInt {
            defer { index += 1 }
            return r[index][0].uint
        }
        let allowance = readsAllowance ? next() : 0
        let rewards = readsRewards ? next() : 0
        let escrow = readsEscrow ? next() : 0
        return LaunchAccountView(tokenBalance: r[0][0].uint, pairBalance: r[2][0].uint, allowance: allowance, snipeTaxBps: LaunchpadABI.int(r[1][0]), pendingRewards: rewards, escrowBalance: escrow)
    }

    /// `BondingCurve.quoteBuy`: previews a buy exactly as the contract would settle it for `recipient`
    /// (the snipe tax depends on who receives the tokens).
    public func quoteBuy(curve: Address, quoteIn: BigUInt, recipient: Address) async throws -> BuyQuote {
        let raw = try await rpc.ethCall(CallRequest(to: curve, data: LaunchpadABI.calldata(LaunchpadABI.Curve.quoteBuy, [.uint(quoteIn), .address(recipient)])))
        return LaunchpadABI.buyQuote(try ABI.decode(raw, "uint256,uint256,uint256,uint256,uint256,uint256"))
    }

    public func quoteSell(curve: Address, tokensIn: BigUInt) async throws -> SellQuote {
        let raw = try await rpc.ethCall(CallRequest(to: curve, data: LaunchpadABI.calldata(LaunchpadABI.Curve.quoteSell, [.uint(tokensIn)])))
        return LaunchpadABI.sellQuote(try ABI.decode(raw, "uint256,uint256,uint256"))
    }

    /// The terms hash a launch must carry (`LaunchInput.expectedEconomics`). Read it right before submitting.
    public func previewLaunchEconomics(configId: BigUInt, pairToken: Address) async throws -> Data {
        guard addresses.isDeployed else { throw LaunchpadError.notDeployed }
        let raw = try await rpc.ethCall(CallRequest(to: addresses.factory, data: LaunchpadABI.calldata(LaunchpadABI.Factory.previewLaunchEconomics, [.uint(configId), .address(pairToken)])))
        return try ABI.decode(raw, "bytes32")[0].bytes
    }

    /// Whether `account` may launch (true unless the whitelist is on and it is not listed).
    public func canLaunch(account: Address) async throws -> Bool {
        guard addresses.isDeployed else { return false }
        let raw = try await rpc.ethCall(CallRequest(to: addresses.factory, data: LaunchpadABI.calldata(LaunchpadABI.Factory.canLaunch, [.address(account)])))
        return try ABI.decode(raw, "bool")[0].bool
    }

    /// The token a launch transaction created, read from the live factory's `TokenLaunched` event. Nil while pending,
    /// when the transaction emitted no launch, or while the live stack is not deployed: an event from any other
    /// emitter (a lookalike in the same transaction) is never taken for the launch.
    public func launchResult(transaction hash: Data) async throws -> LaunchResult? {
        guard addresses.isDeployed, let logs = try await rpc.transactionLogs(hash) else { return nil }
        for log in logs where log.topics.first == LaunchpadABI.Events.launchedTopic && log.address == addresses.factory {
            if let event = LaunchpadABI.launched(log) { return LaunchResult(token: event.token, curve: event.curve, deployer: event.deployer) }
        }
        return nil
    }

    // MARK: - Hydration

    /// Token metadata and live curve state for a page of records from `factory`, in reads of at most
    /// `Multicall.textChunk` launches, all at once (`Multicall.readItems`, which retries a refused read launch by launch), with one
    /// PoolManager read for graduated launches and one metadata read for pair assets not seen before; one launch per
    /// record, in order. A coin's name, symbol, logo, description and links are its creator's: one that can't be read
    /// shows a stand-in (`ChainText.unreadable`, empty for the rest) and the launch keeps its numbers. Its price, reserve,
    /// state and supply are the protocol's: one that fails means the read didn't happen, and this throws
    /// (`ChainListUnread`) rather than leave the launch out or show it wrong. The name, symbol and description are kept
    /// as they show (`ChainText.shown`), so none can reorder or hide the app's text around it; the logo and links are
    /// kept as read (they are only opened, never shown).
    func hydrate(_ records: [LaunchpadABI.LaunchRecord], factory: Address) async throws -> [Launch] {
        try await hydrateReading(records, factory: factory).map(\.launch)
    }

    /// `hydrate`, each launch with its creator's text as the chain holds it when all of it was read (`text`), nil when any
    /// of it stands in as unread: what of a launch the shared list may keep (`LaunchStatics`).
    private func hydrateReading(_ records: [LaunchpadABI.LaunchRecord], factory: Address) async throws -> [(launch: Launch, text: LaunchText?)] {
        guard !records.isEmpty else { return [] }
        typealias T = LaunchpadABI.Token
        typealias C = LaunchpadABI.Curve
        let pairs = try await pairInfos(records.map(\.pairToken))
        let items = records.map { r in
            [
                LaunchpadABI.call(r.token, T.name, returns: "string"),
                LaunchpadABI.call(r.token, T.symbol, returns: "string"),
                LaunchpadABI.call(r.token, T.getTokenInfo, returns: "address,string,string,\(LaunchpadABI.socialsTuple)"),
                LaunchpadABI.call(r.curve, C.price, returns: "uint256"),
                LaunchpadABI.call(r.curve, C.realQuoteReserve, returns: "uint256"),
                LaunchpadABI.call(r.curve, C.completed, returns: "bool"),
                LaunchpadABI.call(r.curve, C.rescued, returns: "bool"),
                LaunchpadABI.call(r.curve, C.launchedAt, returns: "uint64"),
                LaunchpadABI.call(r.token, T.totalSupply, returns: "uint256"),
                LaunchpadABI.call(r.curve, C.getReserves, returns: "uint256,uint256"),
            ]
        }
        let generation = stack(for: factory).generation
        let results = try await multicall.readItems(items, text: Self.launchTextCalls, what: .launch)
        let livePrices = await poolPrices(for: records, pairs: pairs)
        return try records.enumerated().map { i, r in
            let item = results[i]
            func value(_ at: Int) throws -> [ABIValue] { try item[at].get() }
            func text(_ at: Int) -> String? { (try? item[at].get())?.first?.stringOrNil }
            let info = (try? value(2)).map(LaunchpadABI.TokenInfo.init)
            let name = text(0), symbol = text(1)
            let read = LaunchText(name: name ?? ChainText.unreadable, symbol: symbol ?? ChainText.unreadable, logo: info?.logo ?? "",
                                  description: info?.description ?? "", socials: info?.socials ?? Socials())
            let launch = try Self.launch(r, text: read, curvePrice: try value(3)[0].uint, realQuoteReserve: try value(4)[0].uint,
                                         completed: try value(5)[0].bool, rescued: try value(6)[0].bool, launchedAt: LaunchpadABI.int(try value(7)[0]),
                                         supply: try value(8)[0].uint, reserves: { try value(9) }, pairs: pairs, live: livePrices[r.token],
                                         factory: factory, generation: generation)
            return (launch, name != nil && symbol != nil && info != nil ? read : nil)
        }
    }

    /// Launches the device keeps (`LaunchStatics`, in the order given), each with only what moves read: its record (its
    /// phase, what was swept, its pool) and its curve's price, reserve, state and reserves, every launch's in reads of
    /// `Multicall.textChunk` (`Multicall.readItems`, protocol values only, so any that fails throws `ChainListUnread`), then
    /// a graduated one's pool price (`poolPrices`); the rest is what was kept. A record that no longer names the kept
    /// token, curve and pair asset (a file that isn't this chain's) forgets every launch kept of the factory, and throws:
    /// the next read reads them in full. Each launch with its index in the factory's list.
    private func hydrateKnown(_ known: [LaunchStatics], factory: Address) async throws -> [(index: Int, launch: Launch)] {
        guard !known.isEmpty else { return [] }
        typealias C = LaunchpadABI.Curve
        let generation = stack(for: factory).generation
        let legacy = generation.legacyRecord
        async let pairsRead = pairInfos(known.map(\.pairToken))
        let items = known.map { s in
            [
                LaunchpadABI.call(factory, LaunchpadABI.Factory.getLaunchedToken, [.address(s.token)], returns: LaunchpadABI.launchedTokenReturns(legacy: legacy)),
                LaunchpadABI.call(s.curve, C.price, returns: "uint256"),
                LaunchpadABI.call(s.curve, C.realQuoteReserve, returns: "uint256"),
                LaunchpadABI.call(s.curve, C.completed, returns: "bool"),
                LaunchpadABI.call(s.curve, C.rescued, returns: "bool"),
                LaunchpadABI.call(s.curve, C.getReserves, returns: "uint256,uint256"),
            ]
        }
        let results = try await multicall.readItems(items, text: [], what: .launch)
        let pairs = try await pairsRead
        var records: [LaunchpadABI.LaunchRecord] = []
        for (kept, item) in zip(known, results) {
            let record = LaunchpadABI.LaunchRecord(try item[0].get()[0], legacy: legacy)
            guard record.exists, record.token == kept.token, record.curve == kept.curve, record.pairToken == kept.pairToken, let _ = kept.supplyValue else {
                forgetStatics(of: factory)
                throw ChainListUnread(.launch)
            }
            records.append(record)
        }
        let livePrices = await poolPrices(for: records, pairs: pairs)
        return try zip(known, zip(records, results)).map { kept, read in
            let (r, item) = read
            func value(_ at: Int) throws -> [ABIValue] { try item[at].get() }
            let launch = try Self.launch(r, text: kept.text, curvePrice: try value(1)[0].uint, realQuoteReserve: try value(2)[0].uint,
                                         completed: try value(3)[0].bool, rescued: try value(4)[0].bool, launchedAt: kept.launchedAt,
                                         supply: kept.supplyValue ?? 0, reserves: { try value(5) }, pairs: pairs, live: livePrices[r.token],
                                         factory: factory, generation: generation)
            return (kept.index, launch)
        }
    }

    /// One launch from its record (`r`), its creator's text as the chain holds it (made safe to show here,
    /// `ChainText.shown`) and its curve's values: what a launch read in full (`hydrate`) and one kept on the device
    /// (`hydrateKnown`) are both built by, so they read the same. `reserves` (the curve's `getReserves`) is read only for
    /// a coin still on its curve.
    private static func launch(_ r: LaunchpadABI.LaunchRecord, text: LaunchText, curvePrice: BigUInt, realQuoteReserve: BigUInt, completed: Bool, rescued: Bool,
                               launchedAt: Int, supply: BigUInt, reserves: () throws -> [ABIValue], pairs: [Address: PairInfo],
                               live: (price: BigUInt, pairPrice: Double?)?, factory: Address, generation: LaunchpadAddresses.Generation) throws -> Launch {
        let graduated = r.phase == .graduated
        let price = live?.price ?? curvePrice
        // The decimal price: the curve's reserves until it graduates, then its pool's — never the curve's last one.
        let pairPrice = graduated ? live?.pairPrice
            : pairPerCoin(try reserves(), graduated: false, token: r.token, pairSide: r.pairToken, pairDecimals: (pairs[r.pairToken] ?? .mon).decimals)
        return Launch(
            token: r.token, curve: r.curve, deployer: r.deployer, creatorFeeRecipient: r.creatorFeeRecipient, pairToken: r.pairToken,
            graduationThreshold: r.graduationThreshold, creatorTaxBps: r.creatorTaxBps, poolFeeBps: r.poolFeeBps, tickSpacing: r.tickSpacing,
            holderFeeSharing: r.holderFeeSharing, graduationVenue: r.graduationVenue, phase: r.phase, sweptQuote: r.sweptQuote, sweptTokens: r.sweptTokens, sweptAt: r.sweptAt, poolId: r.poolId,
            name: ChainText.shown(text.name), symbol: ChainText.shown(text.symbol), logo: text.logo, description: ChainText.shown(text.description, multiline: true),
            socials: text.socials,
            pair: pairs[r.pairToken] ?? .mon,
            price: price,
            realQuoteReserve: graduated ? r.sweptQuote : realQuoteReserve,
            completed: completed,
            rescued: rescued,
            launchedAt: launchedAt,
            supply: supply,
            marketCap: LaunchpadMath.marketCap(price: price, supply: supply),
            progressBps: LaunchpadMath.progressBps(phase: r.phase, realQuoteReserve: realQuoteReserve, sweptQuote: r.sweptQuote, threshold: r.graduationThreshold),
            factory: factory,
            generation: generation,
            pairPrice: pairPrice
        )
    }

    /// The calls of `hydrate`'s layout that read the creator's text: name, symbol, and getTokenInfo (logo, description,
    /// links). The others read the protocol's values.
    static let launchTextCalls: Set<Int> = [0, 1, 2]

    // MARK: - Kept on the device

    /// The file `store` keeps settled launches in.
    static let staticsFile = "launches.json"

    /// What the device keeps of `factory`'s launches, by index in its list; none without a store.
    private func savedStatics(of factory: Address) -> [Int: LaunchStatics] {
        loadStatics()
        return statics[factory] ?? [:]
    }

    /// Reads `store`'s file once, and again after an erase (its epoch moved), when what memory held goes with it. Nothing
    /// on a fork (`ChainStore.keepsFacts`), as the Moments keep nothing there: a fork restarted while the app runs can
    /// record other launches at the kept indices.
    private func loadStatics() {
        guard let store, store.keepsFacts else { return }
        let epoch = store.epoch
        guard staticsEpoch != epoch else { return }
        staticsEpoch = epoch
        statics = [:]
        for entry in store.load(LaunchStaticsFile.self, from: Self.staticsFile)?.usable ?? [] {
            statics[entry.factory, default: [:]][entry.index] = entry
        }
    }

    /// Keeps `new` and saves the file, unless this device's data was erased since `epoch` (the listing's start). Nothing on
    /// a fork (`loadStatics`).
    private func keepStatics(_ new: [LaunchStatics], readSince epoch: Int) {
        guard let store, store.keepsFacts, !new.isEmpty else { return }
        loadStatics()
        guard staticsEpoch == epoch else { return }
        var changed = false
        for entry in new where statics[entry.factory]?[entry.index] != entry {
            statics[entry.factory, default: [:]][entry.index] = entry
            changed = true
        }
        if changed { store.save(LaunchStaticsFile(statics), to: Self.staticsFile, epoch: epoch) }
    }

    /// Forgets every launch kept of `factory`: its next read reads them in full.
    private func forgetStatics(of factory: Address) {
        guard let store, let epoch = staticsEpoch, statics[factory] != nil else { return }
        statics[factory] = nil
        store.save(LaunchStaticsFile(statics), to: Self.staticsFile, epoch: epoch)
    }

    /// Live pool prices for graduated launches, keyed by token: as `Launch.price` counts it, and to a Double's precision
    /// (`Launch.pairPrice`). Any failure leaves the curve's final price in `price` and no `pairPrice`. A Uniswap v4 pool's
    /// slot0 is read from the PoolManager; a Monday Trade graduation records its v3-style pool address as the `poolId`,
    /// whose own `slot0()` pairs the token with WMON in place of native MON.
    private func poolPrices(for records: [LaunchpadABI.LaunchRecord], pairs: [Address: PairInfo]) async -> [Address: (price: BigUInt, pairPrice: Double?)] {
        var reads: [(record: LaunchpadABI.LaunchRecord, pair: Address, call: ContractCall)] = []
        for record in records where record.phase == .graduated {
            if record.graduationVenue == .monday {
                guard let pool = Address(data: record.poolId.suffix(20)), !pool.isZero else { continue }
                reads.append((record, record.pairToken.isZero ? Monad.wmon : record.pairToken, LaunchpadABI.call(pool, "slot0()", returns: "bytes32")))
            } else if !addresses.poolManager.isZero {
                reads.append((record, record.pairToken, LaunchpadABI.call(addresses.poolManager, LaunchpadABI.PoolManager.extsload, [.bytes(LaunchpadABI.slot0(of: record.poolId))], returns: "bytes32")))
            }
        }
        guard !reads.isEmpty, let results = try? await multicall.read(reads.map(\.call)) else { return [:] }
        var out: [Address: (price: BigUInt, pairPrice: Double?)] = [:]
        for (read, result) in zip(reads, results) {
            guard case .success(let values) = result, let price = LaunchpadMath.poolPrice(slot0: values[0].bytes, token: read.record.token, pairToken: read.pair) else { continue }
            let decimals = (pairs[read.record.pairToken] ?? .mon).decimals
            out[read.record.token] = (price, Self.pairPerCoin(values, graduated: true, token: read.record.token, pairSide: read.pair, pairDecimals: decimals))
        }
        return out
    }

    // MARK: - Transaction plans

    /// The bonding curve a known factory — the live one, then each retired stack — recorded for `token`, read on-chain.
    /// Nil when no known factory launched it or the read fails. A passkey session signs a curve buy or sell (and the
    /// approval for it) only against this address, never one a caller supplied (MERA-PLAN §3).
    public func knownCurve(token: Address) async -> Address? {
        let stacks = stacks.filter(\.isDeployed)
        guard !token.isZero, !stacks.isEmpty else { return nil }
        let calls = stacks.map { LaunchpadABI.call($0.factory, LaunchpadABI.Factory.getLaunchedToken, [.address(token)], returns: LaunchpadABI.launchedTokenReturns(legacy: $0.generation.legacyRecord)) }
        guard let results = try? await multicall.read(calls) else { return nil }
        return Self.knownCurve(stacks: stacks, records: results)
    }

    /// Pure half of `knownCurve`: the first stack whose `getLaunchedToken` record exists and names a curve.
    static func knownCurve(stacks: [LaunchpadAddresses], records: [Result<[ABIValue], Error>]) -> Address? {
        firstRecord(stacks: stacks, records: records)?.record.curve
    }

    /// The first of `stacks` whose `getLaunchedToken` answer (`records`, one per stack, in order) exists and names a
    /// curve; a stack that failed to answer is skipped.
    static func firstRecord(stacks: [LaunchpadAddresses], records: [Result<[ABIValue], Error>]) -> (stack: LaunchpadAddresses, record: LaunchpadABI.LaunchRecord)? {
        for (stack, result) in zip(stacks, records) {
            guard case .success(let values) = result, let tuple = values.first else { continue }
            let record = LaunchpadABI.LaunchRecord(tuple, legacy: stack.generation.legacyRecord)
            if record.exists, !record.curve.isZero { return (stack, record) }
        }
        return nil
    }

    /// Approve the pair asset for the curve when it is an ERC-20, then `buy`. Native MON rides on `value`. Refused for a
    /// launch on a retired launchpad, whatever its phase (`LaunchpadError.retiredLaunchpad`): those curves take sells
    /// only (owner decision 2026-09-28), so nothing is built, not even the approval.
    public func buyPlan(launch: Launch, quoteIn: BigUInt, minTokensOut: BigUInt, recipient: Address) throws -> [TransactionStep] {
        guard !launch.isRetiredLaunchpad else { throw LaunchpadError.retiredLaunchpad }
        var steps: [TransactionStep] = []
        if !launch.pair.isNative {
            steps.append(.approve(token: launch.pairToken, spender: launch.curve, amount: quoteIn, label: L10n.tr("Approve \(launch.pair.symbol)")))
        }
        let data = LaunchpadABI.calldata(LaunchpadABI.Curve.buy, [.uint(quoteIn), .uint(minTokensOut), .address(recipient)])
        steps.append(.call(TransactionRequest(to: launch.curve, data: data, value: launch.pair.isNative ? quoteIn : 0), label: L10n.string(LocalizedStringResource("Buy $\(launch.symbol)", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The value is the coin's symbol after a dollar sign, as coin tickers are written ($DOGE)."))))
        return steps
    }

    /// Approve the token for the curve, then `sell`. Open on every stack: a retired launchpad's holders can always sell.
    public func sellPlan(launch: Launch, tokensIn: BigUInt, minQuoteOut: BigUInt, recipient: Address) -> [TransactionStep] {
        let data = LaunchpadABI.calldata(LaunchpadABI.Curve.sell, [.uint(tokensIn), .uint(minQuoteOut), .address(recipient)])
        return [
            .approve(token: launch.token, spender: launch.curve, amount: tokensIn, label: L10n.string(LocalizedStringResource("Approve $\(launch.symbol)", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The value is the coin's symbol after a dollar sign, as coin tickers are written ($DOGE)."))),
            .call(TransactionRequest(to: launch.curve, data: data), label: L10n.string(LocalizedStringResource("Sell $\(launch.symbol)", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The value is the coin's symbol after a dollar sign, as coin tickers are written ($DOGE)."))),
        ]
    }

    /// `launchToken` on the factory, or `launchAndBuy` on the router when `initialBuy` is set (approving the
    /// pair asset for the router first when it is an ERC-20). `launchFee` is paid in MON on top of a native
    /// developer buy. `from` receives the developer buy. A developer buy is a curve buy, so it is refused when the stack
    /// is a retired one (`LaunchpadError.retiredLaunchpad`), whatever the build is pointed at.
    public func launchPlan(_ input: LaunchInput, launchFee: BigUInt, from: Address) throws -> [TransactionStep] {
        if input.initialBuy > 0, LaunchpadAddresses.isRetired(addresses.factory) { throw LaunchpadError.retiredLaunchpad }
        let params = LaunchpadABI.tokenParams(input)
        let exemptions: ABIValue = .array(input.exemptions.map { .address($0) })
        let label = L10n.string(LocalizedStringResource("Launch $\(input.symbol)", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. It launches a new coin; the value is its symbol after a dollar sign, as coin tickers are written ($DOGE)."))
        guard input.initialBuy > 0 else {
            let data = LaunchpadABI.calldata(LaunchpadABI.Factory.launchToken, [params, .uint(input.configId), .address(input.pairToken), exemptions])
            return [.call(TransactionRequest(to: addresses.factory, data: data, value: launchFee), label: label)]
        }
        var steps: [TransactionStep] = []
        if !input.pairIsNative {
            steps.append(.approve(token: input.pairToken, spender: addresses.router, amount: input.initialBuy, label: L10n.string(LocalizedStringResource("Approve developer buy", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. It approves the pair asset for the coin creator's own first buy, made with the launch."))))
        }
        let data = LaunchpadABI.calldata(LaunchpadABI.Router.launchAndBuy, [
            params, .uint(input.configId), .address(input.pairToken), .uint(input.initialBuy), .uint(input.minTokensOut), .address(from), exemptions,
        ])
        steps.append(.call(TransactionRequest(to: addresses.router, data: data, value: input.pairIsNative ? launchFee + input.initialBuy : launchFee), label: label))
        return steps
    }

    /// `launchPlan` with the launch fee and the economics hash read from the factory first, so the input only
    /// needs what the form collected. `expectedLaunchFee` is the fee the screen showed: the factory's owner can change
    /// `launchFee` at any time with no cap, and the transaction must pay exactly the current one, so a fee that moved
    /// since the screen loaded is refused rather than signed unseen (security audit 2026-09-26, IOST-2).
    /// `expectedEconomics` is the terms hash read with the terms the screen showed (`PairEconomics.economicsHash`): the
    /// launch carries it, so the factory itself rejects terms changed after it was read, and a change seen here is
    /// refused before anything is signed. Without it the hash is read now, which binds nothing the screen showed.
    public func launchPlan(_ input: LaunchInput, from: Address, expectedLaunchFee: BigUInt? = nil, expectedEconomics: Data? = nil) async throws -> [TransactionStep] {
        guard addresses.isDeployed else { throw LaunchpadError.notDeployed }
        if input.initialBuy > 0, LaunchpadAddresses.isRetired(addresses.factory) { throw LaunchpadError.retiredLaunchpad }
        async let fee = multicall.readAll([LaunchpadABI.call(addresses.factory, LaunchpadABI.Factory.launchFee, returns: "uint256")])
        async let economics = previewLaunchEconomics(configId: input.configId, pairToken: input.pairToken)
        async let blocker = launchBlocker(account: from, configId: input.configId)
        // Refused before any step is built: a developer buy's approval would otherwise be signed (and paid for) first.
        if let blocker = try await blocker { throw LaunchpadError.launchBlocked(blocker) }
        var filled = input
        filled.expectedEconomics = try Self.boundEconomics(shown: expectedEconomics, current: try await economics)
        let launchFee = try await fee[0][0].uint
        if let expectedLaunchFee, launchFee != expectedLaunchFee { throw LaunchpadError.launchFeeChanged(launchFee) }
        return try launchPlan(filled, launchFee: launchFee, from: from)
    }

    /// The terms hash a launch carries: the one shown when there is one, refused when the factory's current one differs.
    static func boundEconomics(shown: Data?, current: Data) throws -> Data {
        guard let shown else { return current }
        guard shown == current else { throw LaunchpadError.termsChanged }
        return shown
    }

    /// `HolderFeeSharing.claim(token)` on the launch's own stack: the caller's share of the fees routed to holders.
    /// With a `view`, the creator-fee escrow claim is appended when it holds anything, and the holder claim is
    /// skipped when nothing is pending (each claim reverts with `NothingToClaim` otherwise).
    public func claimRewardsPlan(launch: Launch, view: LaunchAccountView? = nil) -> [TransactionStep] {
        var steps: [TransactionStep] = []
        if view == nil || (view?.pendingRewards ?? 0) > 0 {
            let data = LaunchpadABI.calldata(LaunchpadABI.Sharing.claim, [.address(launch.token)])
            steps.append(.call(TransactionRequest(to: stack(for: launch).holderFeeSharing, data: data), label: L10n.string(LocalizedStringResource("Claim holder rewards", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent."))))
        }
        if let view, view.escrowBalance > 0 {
            steps += claimEscrowPlan(launch: launch)
        }
        return steps
    }

    /// `FeeEscrow.claim()` / `claimToken(pair)` on the launch's own stack: creator fees (and the protocol's) held in
    /// escrow for the caller.
    public func claimEscrowPlan(launch: Launch) -> [TransactionStep] {
        let data = launch.pair.isNative
            ? LaunchpadABI.calldata(LaunchpadABI.Escrow.claim)
            : LaunchpadABI.calldata(LaunchpadABI.Escrow.claimToken, [.address(launch.pairToken)])
        return [.call(TransactionRequest(to: stack(for: launch).escrow, data: data), label: L10n.string(LocalizedStringResource("Claim creator fees", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent.")))]
    }

    /// The caller's claimable fee-escrow balances in `escrow` (the live stack's when nil) — native MON plus each
    /// queried pair token. Creator fees (and, for the treasury address, protocol fees) accrue here per recipient
    /// across ALL of that wallet's launches on the stack, so this is the true "claimable creator fees" figure, keyed
    /// by pair asset rather than by coin.
    public func escrowBalances(account: Address, pairTokens: [Address], escrow: Address? = nil) async throws -> EscrowBalances {
        let escrow = escrow ?? addresses.escrow
        guard !escrow.isZero else { return EscrowBalances(native: 0, tokens: [:]) }
        let tokens = Array(Set(pairTokens.filter { !$0.isZero }))
        var calls: [ContractCall] = [LaunchpadABI.call(escrow, LaunchpadABI.Escrow.balanceOf, [.address(account)], returns: "uint256")]
        for token in tokens { calls.append(LaunchpadABI.call(escrow, LaunchpadABI.Escrow.balanceOfToken, [.address(account), .address(token)], returns: "uint256")) }
        let r = try await multicall.readAll(calls)
        var byToken: [Address: BigUInt] = [:]
        for (i, token) in tokens.enumerated() { byToken[token] = r[i + 1][0].uint }
        return EscrowBalances(native: r[0][0].uint, tokens: byToken)
    }

    /// Every launchpad's fee escrow (the live one's first, then each retired one's, `stacks`) and what `account` can
    /// claim from it: native MON and every pair asset a launch can be made with (`Token.launchpadPairAssets`), plus
    /// `extraPairTokens`, whichever launches were read — a creator's fees in USDC or AUSD are never missed because their
    /// coin isn't among the launches a screen read. An escrow whose read failed has no balances (`LaunchpadEscrowRead`),
    /// never zero.
    public func escrowReads(account: Address, extraPairTokens: [Address] = []) async -> [LaunchpadEscrowRead] {
        var seen = Set<Address>()
        let pairTokens = (Token.launchpadPairAssets + extraPairTokens).filter { !$0.isZero && seen.insert($0).inserted }
        let stacks = stacks.filter { !$0.escrow.isZero }
        return await withTaskGroup(of: (Int, LaunchpadEscrowRead).self) { group in
            for (i, stack) in stacks.enumerated() {
                group.addTask {
                    let balances = try? await self.escrowBalances(account: account, pairTokens: pairTokens, escrow: stack.escrow)
                    return (i, LaunchpadEscrowRead(escrow: stack.escrow, factory: stack.factory, retired: LaunchpadAddresses.retiredStack(for: stack.factory) != nil,
                                                   balances: balances))
                }
            }
            var out: [(Int, LaunchpadEscrowRead)] = []
            for await entry in group { out.append(entry) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Sweeps the caller's balance in `escrow` (the live stack's when nil): the native balance (when `native` is
    /// true) and each listed token, in one plan — so a creator withdraws their fees across every launch on that stack
    /// in a single confirmation.
    public func claimEscrowPlan(native: Bool, tokens: [Address], escrow: Address? = nil) -> [TransactionStep] {
        let escrow = escrow ?? addresses.escrow
        var steps: [TransactionStep] = []
        if native { steps.append(.call(TransactionRequest(to: escrow, data: LaunchpadABI.calldata(LaunchpadABI.Escrow.claim)), label: L10n.string(LocalizedStringResource("Claim MON fees", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent.")))) }
        for token in tokens where !token.isZero {
            steps.append(.call(TransactionRequest(to: escrow, data: LaunchpadABI.calldata(LaunchpadABI.Escrow.claimToken, [.address(token)])), label: L10n.string(LocalizedStringResource("Claim fees", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent."))))
        }
        return steps
    }

    /// `LaunchpadFactory.graduate(token)` on the launch's own factory: retries a stuck migration. Anyone may call it, on
    /// any stack, retired ones included.
    /// Its gas is estimated like any other step (and held to the app's network-fee cap): on v2 plain `graduate` has no
    /// gas floor and can only graduate on the creator's venue or revert, so the estimate never decides the venue.
    public func graduatePlan(launch: Launch) -> [TransactionStep] {
        let data = LaunchpadABI.calldata(LaunchpadABI.Factory.graduate, [.address(launch.token)])
        return [.call(TransactionRequest(to: stack(for: launch).factory, data: data), label: L10n.string(LocalizedStringResource("Graduate", bundle: L10n.kit, comment: "A transaction step: graduate a launch's coin from its bonding curve into its pool (a verb).")))]
    }

    /// `LaunchpadFactory.graduateFallback(token)` — retry the creator's venue, then graduate a stuck Monday launch on
    /// Uniswap v4 — is never sent from the app, on any stack (owner decision 2026-09-28): DyorHQ's keepers send it with
    /// the gas it needs (v2's reverts below 22,062,500 gas, over the app's 15M network-fee cap; the keepers give it about
    /// 29.9M). Always refused with `LaunchpadError.graduateFallbackByKeepers`, so nothing is built for any launch; Retry
    /// Graduation (`graduatePlan`) stays.
    public func graduateFallbackPlan(launch: Launch) throws -> [TransactionStep] {
        throw LaunchpadError.graduateFallbackByKeepers
    }

    /// `MemeHook.sweepPoolFees(poolId, currency)` on the launch's own hook: pays out the fees the hook collected for
    /// a graduated pool.
    public func sweepPoolFeesPlan(launch: Launch, currency: Address? = nil) -> [TransactionStep] {
        let data = LaunchpadABI.calldata(LaunchpadABI.Hook.sweepPoolFees, [.bytes(LaunchpadABI.word(launch.poolId)), .address(currency ?? launch.pairToken)])
        return [.call(TransactionRequest(to: stack(for: launch).hook, data: data), label: L10n.tr("Distribute pool fees"))]
    }

}

/// A launch's creator text as the chain holds it — its token's `name()`, `symbol()` and `getTokenInfo()` logo,
/// description and links — before it is made safe to show (`ChainText.shown`, which every read applies anew).
struct LaunchText: Hashable, Sendable {
    let name: String
    let symbol: String
    let logo: String
    let description: String
    let socials: Socials
}

/// What never changes about a settled launch (`ChainSettled`), kept on the device (`ChainStore`) so the shared launch
/// list reads only what moves (`LaunchpadService.launchListing`): its token at its index in its factory's list (the list
/// only grows), the curve and pair asset its record names (set at launch; the record's phase, sweep, pool and fee
/// recipient do change, and are read every time), and what the token and curve hold with no setter — the creator's
/// text, the supply minted at launch (`LaunchToken` mints once, in its constructor) and the launch time. The text is
/// kept as read, never as shown, and only when it is short (`ChainSettled.maxKeptText`).
struct LaunchStatics: Codable, Hashable, Sendable {
    let factory: Address
    let index: Int
    let token: Address
    let curve: Address
    let pairToken: Address
    let name: String
    let symbol: String
    let logo: String
    let description: String
    /// X (Twitter), Telegram, Discord, website, Farcaster, in `Socials`' order.
    let socials: [String]
    let launchedAt: Int
    /// The supply in wei, in decimal.
    let supply: String

    init(factory: Address, index: Int, record: LaunchpadABI.LaunchRecord, text: LaunchText, launchedAt: Int, supply: BigUInt) {
        self.factory = factory
        self.index = index
        token = record.token
        curve = record.curve
        pairToken = record.pairToken
        name = text.name
        symbol = text.symbol
        logo = text.logo
        description = text.description
        socials = [text.socials.twitter, text.socials.telegram, text.socials.discord, text.socials.website, text.socials.farcaster]
        self.launchedAt = launchedAt
        self.supply = supply.description
    }

    var text: LaunchText {
        let s = socials + Array(repeating: "", count: max(0, 5 - socials.count))
        return LaunchText(name: name, symbol: symbol, logo: logo, description: description,
                          socials: Socials(twitter: s[0], telegram: s[1], discord: s[2], website: s[3], farcaster: s[4]))
    }

    /// The supply, nil when the kept text isn't a number (a damaged file: the launch is then read in full).
    var supplyValue: BigUInt? { BigUInt(supply, radix: 10) }
}

/// The file `LaunchpadService` keeps settled launches in (`launches.json`): a file of another version is ignored, and an
/// entry that can't be read is left out (`ChainStoreEntry`), so those launches are read in full again.
struct LaunchStaticsFile: Codable {
    static let currentVersion = 1

    let version: Int
    let launches: [LaunchStatics]

    init(_ statics: [Address: [Int: LaunchStatics]]) {
        version = Self.currentVersion
        launches = statics.values.flatMap(\.values).sorted { ($0.factory.hex, $0.index) < ($1.factory.hex, $1.index) }
    }

    private enum CodingKeys: String, CodingKey { case version, launches }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        launches = try container.decode([ChainStoreEntry<LaunchStatics>].self, forKey: .launches).compactMap(\.value)
    }

    /// The launches to use: none from a file of another version, and none whose supply can't be read.
    var usable: [LaunchStatics] {
        version == Self.currentVersion ? launches.filter { $0.supplyValue != nil && $0.index >= 0 } : []
    }
}

/// What a launch transaction created, from its `TokenLaunched` event.
public struct LaunchResult: Hashable, Sendable {
    public let token: Address
    public let curve: Address
    public let deployer: Address

    public init(token: Address, curve: Address, deployer: Address) {
        self.token = token
        self.curve = curve
        self.deployer = deployer
    }
}

public extension LaunchpadMath {
    /// `price × supply / 1e18`: market cap in quote wei.
    static func marketCap(price: BigUInt, supply: BigUInt) -> BigUInt {
        price * supply / BigUInt(10).power(18)
    }

    /// Launches by market cap, largest first, across pair assets: each cap in whole pair units (`Launch.marketCapInPair`,
    /// from its decimal price) times its pair asset's USD price (`pairUSD`, by pair token; MON under the zero address),
    /// so a 50,000 USDC coin ranks above a 1 MON one. A launch whose pair has no price yet ranks after every priced one,
    /// by its cap in whole pair units; one whose own price wasn't read counts as no cap. Ties keep the given order.
    static func byMarketCap(_ launches: [Launch], pairUSD: [Address: Double]) -> [Launch] {
        let keyed = launches.enumerated().map { index, launch -> (index: Int, launch: Launch, priced: Bool, value: Double) in
            let units = launch.marketCapInPair ?? 0
            if let usd = pairUSD[launch.pairToken], usd > 0 { return (index, launch, true, units * usd) }
            return (index, launch, false, units)
        }
        return keyed.sorted { a, b in
            if a.priced != b.priced { return a.priced }
            if a.value != b.value { return a.value > b.value }
            return a.index < b.index
        }
        .map(\.launch)
    }

    /// Progress to graduation in basis points: 10 000 once graduated, else raised / threshold with the raise
    /// capped at the threshold.
    static func progressBps(phase: LaunchPhase, realQuoteReserve: BigUInt, sweptQuote: BigUInt, threshold: BigUInt) -> Int {
        if phase == .graduated { return 10_000 }
        if threshold == 0 { return 0 }
        let raised = realQuoteReserve > threshold ? threshold : realQuoteReserve
        return Int(clamping: raised * bps / threshold)
    }

    /// Converts a PoolManager slot0 word into quote wei per 1e18 token wei, the scale `BondingCurve.price`
    /// uses, so graduated launches keep the same price field. Nil when the pool is uninitialised.
    static func poolPrice(slot0 value: Data, token: Address, pairToken: Address) -> BigUInt? {
        let sqrtPriceX96 = BigUInt(value) & ((BigUInt(1) << 160) - 1)
        if sqrtPriceX96 == 0 { return nil }
        let e36 = BigUInt(10).power(36)
        let tokenDecimals = BigUInt(10).power(18)
        // price1Per0 = (sqrtPriceX96 / 2^96)^2, scaled by 1e36 for precision.
        let price1Per0E36 = (sqrtPriceX96 * sqrtPriceX96 * e36) >> 192
        let tokenIsCurrency0 = BigUInt(token.data) < BigUInt(pairToken.data)
        if tokenIsCurrency0 { return price1Per0E36 * tokenDecimals / e36 } // currency1 is the quote
        if price1Per0E36 == 0 { return nil }
        return e36 * tokenDecimals / price1Per0E36 // currency1 is the token, so quote per token = 1 / price
    }
}
