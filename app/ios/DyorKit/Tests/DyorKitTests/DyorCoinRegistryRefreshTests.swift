import BigInt
import XCTest
@testable import DyorKit

/// When the DyorHQ coin registry reads, and what it keeps: a refresh within five minutes of a complete one reads
/// nothing, an incomplete one doesn't count, at most 500 new coins a factory a refresh, `erase` stops what is under way,
/// the file is read entry by entry, and a factory whose count is below what was read is read again. Contract reads come
/// from `MomentsChainStub` (`DyorCoinChain`).
final class DyorCoinRegistryRefreshTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "dyor-coins-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MomentsChainStub.install { _, _ in nil }
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: DyorCoinStore { DyorCoinStore(url: folder.appending(path: DyorCoinStore.fileName())) }

    private func registry(_ chain: DyorCoinChain, store: DyorCoinStore? = nil) -> DyorCoinRegistry {
        chain.install()
        return DyorCoinRegistry(rpc: MomentsChainStub.rpc(), store: store)
    }

    private func launch(_ n: Int, _ symbol: String) -> DyorCoinChain.LaunchCoin {
        let token = Address(literal: String(format: "0x0000000000000000000000000000000000%06x", 0xc00000 + n))
        return DyorCoinChain.LaunchCoin(token: token, name: symbol + " Coin", symbol: symbol, logo: DyorCoinChain.media(DyorCoinChain.creator, "\(n).jpg"),
                                        deployer: DyorCoinChain.creator, curve: Address(data: Data(token.data.reversed()))!)
    }

    private static let v2 = LaunchpadAddresses.monadMainnet.factory

    // MARK: Refresh semantics (F14)

    /// Within 300 s of a complete refresh, `refreshIfStale` reads nothing; after that it reads.
    func testRefreshIfStaleSkipsReadingForFiveMinutesAfterACompleteRefresh() async {
        let registry = registry(.mainnet)
        let first = await registry.refreshIfStale()
        XCTAssertTrue(first)
        XCTAssertEqual(MomentsChainStub.batches().count, 3)
        DyorCoinChain.mainnet.install()
        let soon = await registry.refreshIfStale(now: Date().addingTimeInterval(299))
        XCTAssertTrue(soon)
        XCTAssertTrue(MomentsChainStub.batches().isEmpty, "fresh: nothing read")
        let late = await registry.refreshIfStale(now: Date().addingTimeInterval(301))
        XCTAssertTrue(late)
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "stale: the counts again")
    }

    /// A refresh that left anything unread (a factory that didn't answer) is not fresh: the next `refreshIfStale` reads
    /// again at once, and once one completes, it counts.
    func testAnIncompleteRefreshDoesntCountAsFresh() async {
        var chain = DyorCoinChain.mainnet
        chain.silent = [DyorCoinChain.c2]
        let registry = registry(chain)
        let first = await registry.refreshIfStale()
        XCTAssertFalse(first)
        chain.install()
        _ = await registry.refreshIfStale(now: Date())
        XCTAssertFalse(MomentsChainStub.batches().isEmpty, "read again at once")
        chain.silent = []
        chain.install()
        let healed = await registry.refreshIfStale(now: Date())
        XCTAssertTrue(healed)
        chain.install()
        _ = await registry.refreshIfStale(now: Date().addingTimeInterval(10))
        XCTAssertTrue(MomentsChainStub.batches().isEmpty, "now fresh")
    }

    /// At most 500 new coins of one factory in a refresh; the rest follow in the next.
    func testAtMost500NewCoinsOfAFactoryInARefresh() async {
        var chain = DyorCoinChain()
        chain.launches[Self.v2] = (1...501).map { launch($0, "C\($0)") }
        let registry = registry(chain)
        let first = await registry.refresh()
        XCTAssertFalse(first, "one left for the next refresh")
        var checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[Self.v2], 500)
        var coins = await registry.all
        XCTAssertEqual(coins.count, 500)
        let second = await registry.refresh()
        XCTAssertTrue(second)
        checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[Self.v2], 501)
        coins = await registry.all
        XCTAssertEqual(coins.count, 501)
    }

    /// A node behind the chain can make a brand-new DyorHQ coin read "not DyorHQ" for the session (every factory answered,
    /// none named it yet). The refresh that lists it admits it, and that answer is gone.
    func testACoinARefreshAdmitsOverridesASessionNotDyorHQAnswer() async {
        var chain = DyorCoinChain.mainnet
        let fresh = launch(1, "NEW")
        let registry = registry(chain)
        let before = await registry.prove([fresh.token])
        XCTAssertEqual(before[fresh.token], .notDyor)
        chain.launches[Self.v2] = [fresh]
        chain.install()
        await registry.refresh()
        let after = await registry.membership(fresh.token)
        guard case .dyor(let coin) = after else { return XCTFail("admitted by the refresh: \(after)") }
        XCTAssertEqual(coin.symbol, "NEW")
    }

    /// A DyorHQ coin that reads as a curated token and whose symbol isn't display-safe either gets the imitation warning
    /// — the more telling one — not a plain Unverified, and shows its letters.
    func testALookAlikeThatIsntDisplaySafeGetsTheImitationWarning() async throws {
        var chain = DyorCoinChain()
        var fake = launch(2, "USD\u{0421}\u{200B}")
        fake.name = "USD Coin"
        chain.launches[Self.v2] = [fake]
        let registry = registry(chain)
        await registry.refresh()
        let found = await registry.coin(fake.token)
        let coin = try XCTUnwrap(found)
        XCTAssertFalse(SymbolSafety.isDisplaySafe(coin.symbol))
        XCTAssertEqual(TokenBadge.of(coin.token, coin: coin, receivedUnasked: true), .imitates(.usdc))
        XCTAssertEqual(TokenBadge.of(coin.token, coin: coin, receivedUnasked: false), .imitates(.usdc))
        XCTAssertEqual(CoinIcon.resolve(coin.token, coin: coin, policy: .dyorhq), .letters)
    }

    // MARK: Erase (F10)

    /// `erase` cancels the refresh under way, so a refresh asked for right after it reads the chain afresh rather than
    /// joining the old one (which writes nothing back); and a proof under way writes nothing either.
    func testARefreshRightAfterEraseReadsTheChain() async throws {
        let chain = DyorCoinChain.mainnet
        let gate = DispatchSemaphore(value: 0)
        let first = OnceFlag()
        MomentsChainStub.install { to, data in
            if first.take() { gate.wait() } // hold the very first read
            return chain.answer(to, data)
        }
        let registry = DyorCoinRegistry(rpc: MomentsChainStub.rpc(), store: store)
        let old = Task { await registry.refresh() }
        try await Task.sleep(for: .milliseconds(200))
        await registry.erase()
        let next = Task { await registry.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        gate.signal()
        let oldComplete = await old.value
        let nextComplete = await next.value
        XCTAssertFalse(oldComplete, "the erased refresh writes nothing")
        XCTAssertTrue(nextComplete, "a refresh of its own, not the erased one joined")
        let coins = await registry.all
        XCTAssertEqual(coins.count, 13)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))

        let gate2 = DispatchSemaphore(value: 0)
        let held = OnceFlag()
        MomentsChainStub.install { to, data in
            if held.take() { gate2.wait() }
            return chain.answer(to, data)
        }
        let proving = Task { await registry.prove([Address(literal: "0x000000000000000000000000000000000000abcd")]) }
        try await Task.sleep(for: .milliseconds(200))
        await registry.erase()
        gate2.signal()
        let proof = await proving.value
        XCTAssertEqual(proof[Address(literal: "0x000000000000000000000000000000000000abcd")], .unknown, "an erased proof keeps no answer")
        let afterErase = await registry.all
        XCTAssertTrue(afterErase.isEmpty)
        let again = await registry.prove([DyorCoinChain.qt])
        guard case .dyor? = again[DyorCoinChain.qt] else { return XCTFail("a proof after erase reads the chain") }
    }

    // MARK: The file (F11)

    /// The file is read entry by entry: an entry this build can't read (a launchpad generation a later build added, a
    /// damaged count) is left out, and the rest kept. A coin left out takes its factory's checkpoint with it, so that
    /// list is read again; one whose factory can't be read either takes every checkpoint. Writes stay whole-file and
    /// atomic.
    func testAnEntryTheFileCantReadIsLeftOutAndTheRestKept() throws {
        let coins = [
            DyorCoin(address: DyorCoinChain.qt, origin: .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true), symbol: "QT", name: "Quet",
                     creator: DyorCoinChain.owner, logo: "", pair: .zero),
            DyorCoin(address: Address(literal: "0x0000000000000000000000000000000000000b01"), origin: .launch(factory: Self.v2, generation: .v2, retired: false),
                     symbol: "NEXT", name: "Next", creator: DyorCoinChain.owner, logo: "", pair: .zero),
            DyorCoin(address: Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF"), origin: .moment(factory: DyorCoinChain.c3, id: 1, retired: true), symbol: "NAT",
                     name: "Nature", creator: DyorCoinChain.owner, logo: "", mediaHash: Data(count: 32), mediaIsVideo: true, pair: Monad.usdc),
        ]
        try store.save(DyorCoinStore.Snapshot(coins: coins, checkpoints: [.init(factory: Self.v2, count: 1), .init(factory: DyorCoinChain.legacy, count: 4),
                                                                          .init(factory: DyorCoinChain.c3, count: 1)]))
        let written = try String(contentsOf: store.url, encoding: .utf8)
        var text = written.replacingOccurrences(of: "\"generation\":\"v2\"", with: "\"generation\":\"v9\"")
        text = text.replacingOccurrences(of: "\"count\":4", with: "\"count\":\"four\"")
        try Data(text.utf8).write(to: store.url)
        let snapshot = try XCTUnwrap(store.load(), "one bad entry doesn't discard the file")
        XCTAssertEqual(Set(snapshot.coins.map(\.symbol)), ["QT", "NAT"])
        XCTAssertEqual(snapshot.checkpoints, [.init(factory: DyorCoinChain.c3, count: 1)], "v2's coin was left out, so v2's list is read again; 0xad3d's count was damaged")

        let natOrigin = try XCTUnwrap(written.range(of: #""origin":\{"factory":"[^"]*","id":"1","kind":"moment","retired":true\}"#, options: .regularExpression))
        try Data(written.replacingCharacters(in: natOrigin, with: #""origin":"lost""#).utf8).write(to: store.url)
        let blind = try XCTUnwrap(store.load())
        XCTAssertEqual(Set(blind.coins.map(\.symbol)), ["QT", "NEXT"])
        XCTAssertTrue(blind.checkpoints.isEmpty, "a coin whose factory can't be told sends every list back to be read")
    }

    /// A coin whose entry the file couldn't read is read again at the next refresh — never left out while its factory's
    /// list counts as read.
    func testACoinWhoseEntryWasLeftOutIsReadAgain() async throws {
        var chain = DyorCoinChain.mainnet
        let next = launch(1, "NEXT")
        chain.launches[Self.v2] = [next]
        let first = registry(chain, store: store)
        await first.refresh()
        let text = try String(contentsOf: store.url, encoding: .utf8).replacingOccurrences(of: "\"generation\":\"v2\"", with: "\"generation\":\"v9\"")
        try Data(text.utf8).write(to: store.url)
        let reopened = registry(chain, store: store)
        let before = await reopened.membership(next.token)
        XCTAssertEqual(before, .unknown, "left out of the file")
        let complete = await reopened.refresh()
        XCTAssertTrue(complete)
        guard case .dyor(let coin) = await reopened.membership(next.token) else { return XCTFail("read again at the next refresh") }
        XCTAssertEqual(coin.symbol, "NEXT")
        let checkpoints = await reopened.checkpoints
        XCTAssertEqual(checkpoints[Self.v2], 1)
        let created = await reopened.coins(createdBy: DyorCoinChain.creator).map(\.symbol)
        XCTAssertTrue(created.contains("NEXT"))
    }

    /// A node one launch behind (the app's failover RPC can land on one) answers the live launchpad's count one lower
    /// than what was read. That is the node's lag, not the chain's: every coin of that factory is kept, in memory and in
    /// the file, its checkpoint stays, nothing is read but the counts, and the refresh isn't complete, so the next one
    /// reads again. The newest coin keeps its label and is never asked about on that node.
    func testACountOneBehindKeepsTheFactorysCoins() async throws {
        var chain = DyorCoinChain.mainnet
        chain.launches[Self.v2] = (1...7).map { launch($0, "C\($0)") }
        let registry = registry(chain, store: store)
        let first = await registry.refresh()
        XCTAssertTrue(first)
        let newest = try XCTUnwrap(chain.launches[Self.v2]?.last)
        var behind = chain
        behind.launches[Self.v2]?.removeLast()
        behind.install()
        let lagging = await registry.refresh()
        XCTAssertFalse(lagging, "a count below what was read isn't a complete refresh")
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "the counts alone")
        let coins = await registry.all
        XCTAssertEqual(coins.values.filter { $0.factory == Self.v2 }.count, 7, "no coin dropped")
        let checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[Self.v2], 7)
        XCTAssertEqual(try XCTUnwrap(store.load()).coins.filter { $0.factory == Self.v2 }.count, 7, "nor from the file")
        behind.install()
        let proof = await registry.prove([newest.token])
        guard case .dyor? = proof[newest.token] else { return XCTFail("the newest coin keeps its label") }
        XCTAssertTrue(MomentsChainStub.batches().isEmpty, "and is never asked about on the lagging node")
        behind.install()
        _ = await registry.refreshIfStale()
        XCTAssertFalse(MomentsChainStub.batches().isEmpty, "not fresh: read again at once")
        chain.install()
        let caughtUp = await registry.refresh()
        XCTAssertTrue(caughtUp)
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "the counts alone: nothing was dropped to read again")
    }

    /// A factory whose count stays below what the file says was read — a fork restarted under the same file — for ten
    /// minutes (`lowerCountGrace`) has its stored coins dropped and its list read again from the start; every other
    /// factory's coins stay, and the file is rewritten without them. A count that reaches the checkpoint in between
    /// starts the wait again.
    func testACountBelowTheCheckpointForTenMinutesDropsThatFactorysCoinsAndReadsThemAgain() async throws {
        let ghosts = (1...3).map { n in
            DyorCoin(address: Address(literal: String(format: "0x00000000000000000000000000000000%08x", 0x9000 + n)), origin: .launch(factory: Self.v2, generation: .v2, retired: false),
                     symbol: "GHOST\(n)", name: "Ghost", creator: DyorCoinChain.creator, logo: "", pair: .zero)
        }
        let qt = DyorCoin(address: DyorCoinChain.qt, origin: .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true), symbol: "QT", name: "Quet",
                          creator: DyorCoinChain.owner, logo: DyorCoinChain.media(DyorCoinChain.owner, "0136f3f3-24cf-45e5-b4d8-1f68423c36cf.jpg"), pair: .zero)
        try store.save(DyorCoinStore.Snapshot(coins: ghosts + [qt], checkpoints: [.init(factory: Self.v2, count: 3), .init(factory: DyorCoinChain.legacy, count: 4)]))
        var chain = DyorCoinChain.mainnet
        let real = launch(7, "REAL")
        chain.launches[Self.v2] = [real]
        let registry = registry(chain, store: store)
        let start = Date()
        var complete = await registry.refresh(now: start)
        XCTAssertFalse(complete)
        var coins = await registry.all
        XCTAssertEqual(Set(coins.values.filter { $0.factory == Self.v2 }.map(\.symbol)), ["GHOST1", "GHOST2", "GHOST3"], "kept while it may be a node behind")
        chain.install()
        complete = await registry.refresh(now: start.addingTimeInterval(DyorCoinRegistry.lowerCountGrace - 1))
        XCTAssertFalse(complete)
        coins = await registry.all
        XCTAssertNil(coins[real.token])
        chain.install()
        complete = await registry.refresh(now: start.addingTimeInterval(DyorCoinRegistry.lowerCountGrace))
        XCTAssertTrue(complete)
        coins = await registry.all
        XCTAssertEqual(Set(coins.values.filter { $0.factory == Self.v2 }.map(\.symbol)), ["REAL"], "the fork's coins are gone")
        XCTAssertEqual(coins[DyorCoinChain.qt]?.symbol, "QT", "other factories' coins stay")
        XCTAssertEqual(coins.count, 11, "QT from the file (0xad3d's list was read to its count), the other factories' 9, and REAL")
        let checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[Self.v2], 1)
        let kept = try XCTUnwrap(store.load())
        XCTAssertFalse(kept.coins.contains { $0.symbol.hasPrefix("GHOST") })

        // A count that reaches the checkpoint starts the wait again.
        let again = DyorCoinRegistry(rpc: MomentsChainStub.rpc())
        var full = DyorCoinChain.mainnet
        full.launches[Self.v2] = [launch(8, "ONE"), launch(9, "TWO")]
        full.install()
        await again.refresh(now: start)
        var short = full
        short.launches[Self.v2]?.removeLast()
        short.install()
        await again.refresh(now: start.addingTimeInterval(60))
        full.install()
        await again.refresh(now: start.addingTimeInterval(120))
        short.install()
        await again.refresh(now: start.addingTimeInterval(700))
        short.install()
        complete = await again.refresh(now: start.addingTimeInterval(700 + DyorCoinRegistry.lowerCountGrace - 1))
        XCTAssertFalse(complete)
        let both = await again.all.values.filter { $0.factory == Self.v2 }.count
        XCTAssertEqual(both, 2, "ten minutes from the last time it was seen lower, not the first")
    }
}

/// True the first time it is taken, false after.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
