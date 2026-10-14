import BigInt
import XCTest
@testable import DyorKit

/// What the server's history adds to the store (`HistoryStore.adopt`, the server spec's §16 steps 1–8): only the blocks a
/// read proves, with the logs the scan matches in them; the newer head; the higher cap floor; a transfer scan's floor at
/// genesis only after a full read served it whole; serialised with the refreshes; nothing kept across an erase or an
/// epoch reset; the first transaction only ever earlier; and the files kept before it still loading.
final class HistoryAdoptTests: XCTestCase {
    private let wallet = HistoryDocs.wallet
    private let head = HistoryDocs.head
    private var directory: URL!
    private let gate = HoldGate()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-adopt-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        gate.open()
        LogsStub.install(head: 0) { _ in nil }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func router() -> LogsRouter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        return LogsRouter(endpoints: [LogsEndpoint(url: URL(string: "https://wide.logs-stub.invalid")!, span: 10_000, clamps: false)], session: URLSession(configuration: configuration),
                          gate: LogsGate(inFlight: 8, interval: .zero), concurrency: 1)
    }

    private func read(_ pages: [String?: Data] = HistoryDocs.threePages(), limits: HistoryServerClient.Limits = .standard, from: UInt64? = nil,
                      to: UInt64? = nil) async throws -> ServerHistoryRead {
        try await HistoryPagesStub(pages: pages).client(limits).read(wallet: wallet, from: from, to: to)
    }

    private var out: HistoryScan { HistoryDocs.scan(WalletHistoryScans.transfersOutId) }
    private var incoming: HistoryScan { HistoryDocs.scan(WalletHistoryScans.transfersInId) }
    private var launchpad: HistoryScan { HistoryDocs.scan(WalletHistoryScans.launchpadId) }
    /// The transfer scans' own floor at the server's head: 30 days back (the wallet's first transaction unknown).
    private var windowFloor: UInt64 { head - WalletHistoryScans.transferBlocks }

    /// `store.adopt` of what `read` holds of `scan`, which must be taken in.
    private func adopted(_ read: ServerHistoryRead, _ scan: HistoryScan, into store: HistoryStore, token: Int = 0, epoch: Int = 0,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> HistoryEntry {
        let account = try XCTUnwrap(read.scan(scan), file: file, line: line)
        let entry = await store.adopt(account, scan: scan, wallet: wallet, erasureToken: token, epoch: epoch)
        return try XCTUnwrap(entry, "refused", file: file, line: line)
    }

    /// The three-page read's account of `scan`.
    private func serverScan(_ scan: HistoryScan) async throws -> ServerScan {
        let full = try await read()
        return try XCTUnwrap(full.scan(scan))
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting")
    }

    // MARK: Merge and floors

    /// A full read that served a transfer scan whole from genesis: its blocks up to 1,200 below the server's head join
    /// the entry with the logs in them (the one in the margin left to the device), the head moves to the server's, the
    /// floor to genesis, and the entry is kept on disk with its epoch.
    func testAFullReadMergesWhatItProvesAndMovesTheTransferFloorToGenesis() async throws {
        let store = HistoryStore(router: router(), directory: directory)
        let token = await store.erasureToken()
        let server = try await read()
        let entry = try await adopted(server, out, into: store, token: token, epoch: 4)
        XCTAssertEqual(entry.covered, [0...(head - 1_200)])
        XCTAssertEqual(entry.logs.map(\.blockNumber), [50_000_000, 108_000_000, 109_000_000, 110_000_000, 110_000_000], "block order; the log 100 below the head left out")
        XCTAssertEqual(entry.floorOverride, 0)
        XCTAssertEqual(entry.floor, 0)
        XCTAssertEqual(entry.head, head)
        XCTAssertEqual(entry.headTimestamp, HistoryDocs.headTimestamp)
        XCTAssertEqual(entry.serverEpoch, 4)
        XCTAssertNil(entry.capFloor)
        XCTAssertNotNil(entry.updatedAt)
        XCTAssertFalse(entry.complete, "the newest 1,200 blocks are the device's to read")
        XCTAssertEqual(entry.unread, 1_200)

        let kept = await HistoryStore(router: router(), directory: directory).cached(out, wallet: wallet)
        XCTAssertEqual(kept.covered, entry.covered)
        XCTAssertEqual(kept.logs, entry.logs)
        XCTAssertEqual(kept.floorOverride, 0)
        XCTAssertEqual(kept.serverEpoch, 4)
        let file = try String(contentsOf: directory.appendingPathComponent(wallet.hex).appendingPathComponent("transfers-out.json"), encoding: .utf8)
        XCTAssertTrue(file.contains(#""floorOverride":0"#) && file.contains(#""serverEpoch":4"#))

        // The next round reads the newest blocks from `overlap` below the newest covered one: one range, to the head.
        LogsStub.install(head: head + 300, logs: [HistoryDocs.log(head - 100, scan: out)]) { _ in nil }
        let refreshed = await store.refresh(out, wallet: wallet, budget: LogsBudget(requests: 5, seconds: 10))
        XCTAssertTrue(refreshed.complete)
        XCTAssertEqual(refreshed.floor, 0, "genesis, as proved")
        XCTAssertEqual(LogsStub.queries(), [LogsStub.Range(from: head - 1_200 - HistoryStore.overlap, to: head + 300)])
        XCTAssertEqual(refreshed.logs.last?.blockNumber, head - 100)
        XCTAssertEqual(refreshed.serverEpoch, 4, "still holding the server's history")
    }

    /// The transfer floor moves to genesis only after a full read that served the scan whole with nothing left out: a
    /// scan with a hole, a bounded read, a read cut short, an omitted log — each keeps the scan's own floor, and what
    /// lies below it is dropped. A global scan's floor is the same on both sides.
    func testTheTransferFloorMovesOnlyOnAProvenFullRead() async throws {
        let full = try await read()
        let store = HistoryStore(router: router(), directory: nil)
        let token = await store.erasureToken()

        let holed = try await adopted(full, incoming, into: store, token: token, epoch: 0)
        XCTAssertNil(holed.floorOverride, "a hole: not served whole")
        XCTAssertEqual(holed.floor, windowFloor)
        XCTAssertEqual(holed.covered, [windowFloor...(HistoryDocs.inHole - 1), (HistoryDocs.inHole + 1)...(head - 1_200)], "the hole a gap the device reads")
        XCTAssertEqual(holed.logs.map(\.blockNumber), [103_500_000, 111_000_000])

        let bounded = try await read(from: 0, to: head)
        let boundedEntry = try await adopted(bounded, out, into: HistoryStore(router: router(), directory: nil), token: 0, epoch: 0)
        XCTAssertNil(boundedEntry.floorOverride, "a bounded read")
        XCTAssertEqual(boundedEntry.floor, windowFloor)
        XCTAssertEqual(boundedEntry.covered, [windowFloor...(head - 1_200)])
        XCTAssertEqual(boundedEntry.logs.map(\.blockNumber), [108_000_000, 109_000_000, 110_000_000, 110_000_000], "the log below the floor dropped")

        let short = try await read(limits: .init(pages: 1, seconds: 15))
        let shortEntry = try await adopted(short, out, into: HistoryStore(router: router(), directory: nil), token: 0, epoch: 0)
        XCTAssertNil(shortEntry.floorOverride, "a read cut short")
        XCTAssertEqual(shortEntry.covered, [109_000_001...(head - 1_200)])
        XCTAssertEqual(shortEntry.logs.map(\.blockNumber), [110_000_000, 110_000_000])

        var pages = HistoryDocs.threePages()
        var one = try XCTUnwrap(JSONSerialization.jsonObject(with: pages[String?.none]!) as? [String: Any])
        var scans = one["scans"] as! [String: Any]
        scans[WalletHistoryScans.transfersOutId] = HistoryDocs.account(WalletHistoryScans.transfersOutId, omitted: [80_000_000], logs: HistoryDocs.outFirst)
        one["scans"] = scans
        pages[String?.none] = HistoryDocs.data(one)
        let omitted = try await read(pages)
        let omittedEntry = try await adopted(omitted, out, into: HistoryStore(router: router(), directory: nil), token: 0, epoch: 0)
        XCTAssertNil(omittedEntry.floorOverride, "an omitted log")
        XCTAssertEqual(omittedEntry.floor, windowFloor)

        // A document that says complete over a gap: the floor stays, and the gap below it is never the device's to read.
        scans[WalletHistoryScans.transfersOutId] = HistoryDocs.account(WalletHistoryScans.transfersOutId, covered: [[0, 1_000], [50_000_000, head]], complete: true,
                                                                       logs: HistoryDocs.outFirst)
        one["scans"] = scans
        pages[String?.none] = HistoryDocs.data(one)
        let gapped = try await read(pages)
        XCTAssertTrue(try XCTUnwrap(gapped.scan(out)).complete, "what it says")
        XCTAssertNil(HistoryStore.provedFloor(try XCTUnwrap(gapped.scan(out)), for: out))
        let gappedEntry = try await adopted(gapped, out, into: HistoryStore(router: router(), directory: nil))
        XCTAssertNil(gappedEntry.floorOverride, "a gap the document shows")
        XCTAssertEqual(gappedEntry.floor, windowFloor)
        XCTAssertEqual(gappedEntry.covered, [windowFloor...(head - 1_200)])
        XCTAssertEqual(HistoryStore.provedFloor(try XCTUnwrap(full.scan(out)), for: out), 0)

        // The wallet's first transaction known older than the window: the floor there, what lies below it dropped.
        let firstKnown = WalletHistoryScans.transfersOut(wallet: wallet, floor: .earliest(block: 90_000_000, blocks: WalletHistoryScans.transferBlocks))
        let deeper = try await adopted(bounded, firstKnown, into: HistoryStore(router: router(), directory: nil), token: 0, epoch: 0)
        XCTAssertEqual(deeper.floor, 90_000_000)
        XCTAssertEqual(deeper.covered, [90_000_000...(head - 1_200)])

        let global = try await adopted(full, launchpad, into: store, token: token, epoch: 0)
        XCTAssertNil(global.floorOverride, "a global scan: the same floor on both sides")
        XCTAssertEqual(global.floor, LaunchpadAddresses.feeHistoryStart)
        XCTAssertEqual(global.covered, [LaunchpadAddresses.feeHistoryStart...(head - 1_200)])
        XCTAssertEqual(global.logs.map(\.blockNumber), [104_000_000, head - 5_000])
    }

    /// The cap floor is the higher of the entry's and the read's, and the floor never goes below it; holes never raise it.
    func testTheCapFloorIsTheHigherOfTheTwo() async throws {
        let capped = try await read(HistoryDocs.threePages(capTwo: 50_000_000))
        let entry = try await adopted(capped, out, into: HistoryStore(router: router(), directory: nil), token: 0, epoch: 0)
        XCTAssertEqual(entry.capFloor, 50_000_000)
        XCTAssertEqual(entry.floorOverride, 50_000_000, "genesis, or the cap floor above it")
        XCTAssertEqual(entry.floor, 50_000_000)
        XCTAssertEqual(entry.covered, [50_000_000...(head - 1_200)])

        // The device's own cap floor higher still: it stands, and the logs below it go.
        let folder = directory.appendingPathComponent(wallet.hex)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":2,"query":"\#(out.query.fingerprint)","covered":[[60000000,61000000]],"head":61000000,"headTimestamp":1,"floor":60000000,"capFloor":60000000,"logs":[]}"#.utf8)
            .write(to: folder.appendingPathComponent("transfers-out.json"))
        let higher = try await adopted(capped, out, into: HistoryStore(router: router(), directory: directory), token: 0, epoch: 0)
        XCTAssertEqual(higher.capFloor, 60_000_000)
        XCTAssertEqual(higher.floor, 60_000_000)
        XCTAssertEqual(higher.covered, [60_000_000...(head - 1_200)])
        XCTAssertFalse(higher.logs.contains { $0.blockNumber < 60_000_000 })

        let holed = try await adopted(capped, incoming, into: HistoryStore(router: router(), directory: nil), token: 0, epoch: 0)
        XCTAssertNil(holed.capFloor, "a hole is a gap, never a cap")
    }

    // MARK: Refusals

    /// Nothing is taken in, and nothing changes, unless the server's filter takes the scan's, the read proves some blocks
    /// within its bounds (never the metadata alone), the scan is the same, no erase came since the token, and the epoch
    /// is no lower than the one applied.
    func testAnAdoptionRefusesWhatItCantProve() async throws {
        let full = try await read()
        let store = HistoryStore(router: router(), directory: directory)
        let token = await store.erasureToken()
        let server = try XCTUnwrap(full.scan(out))

        let moments = HistoryDocs.scan(WalletHistoryScans.momentsId)
        let ahead = HistoryScan(id: moments.id, query: LogsQuery(addresses: moments.query.addresses + [HistoryDocs.counterparty], topics: moments.query.topics), floor: moments.floor)
        let refusedAhead = await store.adopt(try XCTUnwrap(full.scan(moments)), scan: ahead, wallet: wallet, erasureToken: token, epoch: 0)
        XCTAssertNil(refusedAhead, "the app knows a cohort the server doesn't")
        let refusedOther = await store.adopt(server, scan: incoming, wallet: wallet, erasureToken: token, epoch: 0)
        XCTAssertNil(refusedOther, "another scan's")

        var scans: [String: [String: Any]] = [:]
        for id in HistoryServerClient.scanOrder { scans[id] = HistoryDocs.account(id) }
        let meta = try await HistoryPagesStub(pages: [String?.none: HistoryDocs.data(HistoryDocs.page(scans: scans, next: nil))]).client().metadata(wallet: wallet)
        let metaScan = try XCTUnwrap(meta.scan(out))
        XCTAssertFalse(metaScan.adoptable.isEmpty)
        let refusedMeta = await store.adopt(metaScan, scan: out, wallet: wallet, erasureToken: token, epoch: 0)
        XCTAssertNil(refusedMeta, "the metadata alone: no logs to take in")

        let short = try await read(limits: .init(pages: 1, seconds: 15))
        let refusedEmpty = await store.adopt(try XCTUnwrap(short.scan(incoming)), scan: incoming, wallet: wallet, erasureToken: token, epoch: 0)
        XCTAssertNil(refusedEmpty, "nothing adoptable")

        let outside = ServerScan(id: server.id, kind: server.kind, defVersion: 1, query: server.query, fingerprint: "", floor: 0, capSeen: nil, from: 100, to: 200,
                                 covered: [100...200], holes: [], head: head, headTimestamp: 1, complete: true, omittedBlocks: [], omittedTruncated: false, finished: true,
                                 lowestServedBlock: nil, bounded: false, metaOnly: false, logs: [], adoptable: [50...300])
        XCTAssertFalse(HistoryStore.takes(outside, for: out), "blocks outside the bounds the read speaks for")
        XCTAssertTrue(HistoryStore.takes(server, for: out))

        await store.apply(epoch: 3)
        let refusedEpoch = await store.adopt(server, scan: out, wallet: wallet, erasureToken: token, epoch: 2)
        XCTAssertNil(refusedEpoch, "read under an epoch the owner moved past")

        await store.forget(wallet: HistoryDocs.counterparty)
        let refusedErased = await store.adopt(server, scan: out, wallet: wallet, erasureToken: token, epoch: 3)
        XCTAssertNil(refusedErased, "an erase since the token")
        let untouched = await store.cached(out, wallet: wallet)
        XCTAssertEqual(untouched, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(wallet.hex).path), "nothing written")

        let pastTheChain = await store.adopt(server, scan: out, wallet: wallet, erasureToken: await store.erasureToken(), epoch: 3, chainHead: head - 1)
        XCTAssertNil(pastTheChain, "a head past the chain's: blocks the device can't prove exist")
        let accepted = await store.adopt(server, scan: out, wallet: wallet, erasureToken: await store.erasureToken(), epoch: 3, chainHead: head)
        XCTAssertEqual(accepted?.serverEpoch, 3)
    }

    /// The service reads the chain's head before it takes a read in: a read ahead of it, or no head, adds nothing.
    func testTheServiceTakesNothingAheadOfTheChain() async throws {
        let store = HistoryStore(router: router(), directory: nil)
        let client = LogsStub.rpc()
        let clock = BlockClock(rpc: client, measured: BlockClock.fallbackSecondsPerBlock)
        let service = WalletHistoryService(store: store, swapHistory: SwapHistoryService(rpc: client, clock: clock), clock: clock,
                                           stacks: { DyorCoinRegistry.launchpads(live: .monadMainnet) }, cohorts: DyorCoinRegistry.cohorts(live: .monadMainnet))
        let full = try await read()
        LogsStub.install(head: head - 1) { _ in nil }
        let behind = await service.adopt(full, wallet: wallet, erasureToken: 0, epoch: 0)
        XCTAssertEqual(behind, [], "the server's head past the chain's")
        LogsStub.installHeadFailure()
        let unreachable = await service.adopt(full, wallet: wallet, erasureToken: 0, epoch: 0)
        XCTAssertEqual(unreachable, [], "no head to check against")
        for id in WalletHistoryScans.ids {
            let entry = await store.cached(HistoryDocs.scan(id), wallet: wallet)
            XCTAssertEqual(entry, .empty, id)
        }
        LogsStub.install(head: head) { _ in nil }
        let taken = await service.adopt(full, wallet: wallet, erasureToken: 0, epoch: 0)
        XCTAssertEqual(taken, Set(WalletHistoryScans.ids))
    }

    // MARK: Serialised with the refreshes

    /// The lost update: a refresh under way started from the entry before the adoption; written after it, it would drop
    /// what the adoption added. The adoption waits for it and merges into what it kept: both are there.
    func testAnAdoptionWaitsForARefreshUnderWay() async throws {
        let top = HistoryDocs.log(head + 100, scan: out)
        let held = head + 100
        LogsStub.install(head: head + 300, logs: [top], holding: { $0.contains(held) }) { _ in nil }
        let store = HistoryStore(router: router(), directory: directory)
        let token = await store.erasureToken()
        let server = try await serverScan(out)
        let refreshing = Task { await store.refresh(self.out, wallet: self.wallet, budget: LogsBudget(requests: 1, seconds: 10)) }
        try await waitUntil { LogsStub.held() > 0 }
        let adopting = Task { await store.adopt(server, scan: self.out, wallet: self.wallet, erasureToken: token, epoch: 0) }
        try await Task.sleep(for: .milliseconds(200))
        let during = await store.cached(out, wallet: wallet)
        XCTAssertEqual(during.covered, [], "the adoption waits")
        LogsStub.release()
        let refreshed = await refreshing.value
        let adoptedValue = await adopting.value
        let adopted = try XCTUnwrap(adoptedValue)
        XCTAssertTrue(refreshed.logs.contains(top))
        XCTAssertTrue(adopted.logs.contains(top), "the refresh's read kept")
        XCTAssertTrue(adopted.logs.contains { $0.blockNumber == 50_000_000 }, "the server's taken in")
        XCTAssertEqual(adopted.covered, [0...(head + 300)])
        XCTAssertTrue(adopted.complete)
        let held2 = await store.cached(out, wallet: wallet)
        XCTAssertEqual(held2, adopted)
        let kept = await HistoryStore(router: router(), directory: directory).cached(out, wallet: wallet)
        XCTAssertEqual(kept.covered, adopted.covered)
    }

    /// A refresh asked while an adoption works joins it: the adoption's entry, no read of its own over it.
    func testARefreshAskedDuringAnAdoptionJoinsIt() async throws {
        // A local fork's first block is asked once per endpoint (`LogsRouter.localForkBlock`): held here, the adoption
        // waits in the middle of its work.
        let gate = self.gate
        LogsStub.install(head: head, answer: { _, method, _ in
            guard method == "anvil_metadata" else { return nil }
            gate.enterAndWait()
            return .object(["forkedNetwork": .object(["forkBlockNumber": .number(0)])])
        }) { _ in nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let local = LogsRouter(endpoints: [LogsEndpoint(url: URL(string: "https://localhost:\(Int.random(in: 20_000..<60_000))")!, span: 50_000, clamps: false)],
                               session: URLSession(configuration: configuration), gate: LogsGate(inFlight: 8, interval: .zero))
        let store = HistoryStore(router: local, directory: nil)
        let server = try await serverScan(out)
        let adopting = Task { await store.adopt(server, scan: self.out, wallet: self.wallet, erasureToken: 0, epoch: 0) }
        try await waitUntil { gate.entered }
        let refreshing = Task { await store.refresh(self.out, wallet: self.wallet, budget: LogsBudget(requests: 5, seconds: 5)) }
        try await Task.sleep(for: .milliseconds(200))
        gate.open()
        let adoptedValue = await adopting.value
        let adopted = try XCTUnwrap(adoptedValue)
        let refreshed = await refreshing.value
        XCTAssertEqual(refreshed, adopted, "joined")
        XCTAssertEqual(LogsStub.queries(), [], "no read of its own")
    }

    /// An erase while an adoption waits for a refresh: neither keeps anything, in memory or on disk.
    func testAnEraseWhileAnAdoptionWaitsKeepsNothing() async throws {
        let held = head + 100
        LogsStub.install(head: head + 300, logs: [HistoryDocs.log(held, scan: out)], holding: { $0.contains(held) }) { _ in nil }
        let store = HistoryStore(router: router(), directory: directory)
        let token = await store.erasureToken()
        let server = try await serverScan(out)
        let refreshing = Task { await store.refresh(self.out, wallet: self.wallet, budget: LogsBudget(requests: 1, seconds: 10)) }
        try await waitUntil { LogsStub.held() > 0 }
        let adopting = Task { await store.adopt(server, scan: self.out, wallet: self.wallet, erasureToken: token, epoch: 0) }
        try await Task.sleep(for: .milliseconds(100))
        await store.forget(wallet: wallet)
        LogsStub.release()
        _ = await refreshing.value
        let adopted = await adopting.value
        XCTAssertNil(adopted)
        let after = await store.cached(out, wallet: wallet)
        XCTAssertEqual(after, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(wallet.hex).path))
    }

    // MARK: Erasure and the epoch

    /// Forgetting the wallet drops what the server's history added with the rest: its logs, floor and epoch.
    func testForgettingTheWalletDropsTheServersHistory() async throws {
        let store = HistoryStore(router: router(), directory: directory)
        let adopted = await store.adopt(try await serverScan(out), scan: out, wallet: wallet, erasureToken: 0, epoch: 1)
        XCTAssertEqual(adopted?.floorOverride, 0)
        await store.forget(wallet: wallet)
        let forgotten = await store.cached(out, wallet: wallet)
        XCTAssertEqual(forgotten, .empty)
        let reloaded = await HistoryStore(router: router(), directory: directory).cached(out, wallet: wallet)
        XCTAssertNil(reloaded.floorOverride)
        XCTAssertNil(reloaded.serverEpoch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(wallet.hex).path))
    }

    /// The owner's epoch: an entry that took the server's history in under a lower one is reset — in memory, on disk, and
    /// when loaded later by a store that applied the higher one — and no adoption under a lower one is kept; entries that
    /// never took it in are untouched.
    func testTheEpochResetsWhatTheServerAdded() async throws {
        LogsStub.install(head: head, logs: []) { _ in nil }
        let store = HistoryStore(router: router(), directory: directory)
        let server = try await serverScan(out)
        await store.apply(epoch: 1)
        let adopted = await store.adopt(server, scan: out, wallet: wallet, erasureToken: 0, epoch: 1)
        XCTAssertEqual(adopted?.serverEpoch, 1)
        let moments = HistoryDocs.scan(WalletHistoryScans.momentsId)
        let chainOnly = await store.refresh(moments, wallet: wallet, budget: LogsBudget(requests: 1, seconds: 5))
        XCTAssertNil(chainOnly.serverEpoch)
        let folder = directory.appendingPathComponent(wallet.hex)
        let momentsFile = try String(contentsOf: folder.appendingPathComponent("moments.json"), encoding: .utf8)
        XCTAssertFalse(momentsFile.contains("serverEpoch") || momentsFile.contains("floorOverride"), "nil: left out of the file")

        let same = await store.apply(epoch: 1)
        XCTAssertEqual(same, 0, "the same epoch resets nothing")
        let reset = await store.apply(epoch: 2)
        XCTAssertEqual(reset, 1)
        let cleared = await store.cached(out, wallet: wallet)
        XCTAssertEqual(cleared, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transfers-out.json").path))
        let untouched = await store.cached(moments, wallet: wallet)
        XCTAssertEqual(untouched, chainOnly, "never took it in: untouched")
        let stale = await store.adopt(server, scan: out, wallet: wallet, erasureToken: 0, epoch: 1)
        XCTAssertNil(stale, "a read under the old epoch")

        // On disk only: reset when a store that applied a higher epoch loads it.
        _ = await store.adopt(server, scan: out, wallet: wallet, erasureToken: 0, epoch: 2)
        let later = HistoryStore(router: router(), directory: directory)
        await later.apply(epoch: 3)
        let loaded = await later.cached(out, wallet: wallet)
        XCTAssertEqual(loaded, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transfers-out.json").path))
        let unaffected = await HistoryStore(router: router(), directory: directory).cached(moments, wallet: wallet)
        XCTAssertEqual(unaffected.covered, chainOnly.covered)
    }

    /// A refresh under way when the epoch resets the entry keeps nothing it read, and gives back what is held now.
    func testARefreshUnderWayDuringAnEpochResetKeepsNothing() async throws {
        let held = head + 100
        LogsStub.install(head: head + 300, logs: [HistoryDocs.log(held, scan: out)], holding: { $0.contains(held) }) { _ in nil }
        let store = HistoryStore(router: router(), directory: directory)
        _ = await store.adopt(try await serverScan(out), scan: out, wallet: wallet, erasureToken: 0, epoch: 0)
        let refreshing = Task { await store.refresh(self.out, wallet: self.wallet, budget: LogsBudget(requests: 1, seconds: 10)) }
        try await waitUntil { LogsStub.held() > 0 }
        let reset = await store.apply(epoch: 1)
        XCTAssertEqual(reset, 1)
        LogsStub.release()
        let refreshed = await refreshing.value
        XCTAssertEqual(refreshed, .empty, "what is held now, not the server's history it started from")
        let held2 = await store.cached(out, wallet: wallet)
        XCTAssertEqual(held2, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(wallet.hex).appendingPathComponent("transfers-out.json").path))
    }

    /// A file kept before this build (no `floorOverride`, no `serverEpoch`) loads as it is.
    func testAFileKeptBeforeLoads() async throws {
        let log = HistoryDocs.log(100_000_000, scan: out, timestamp: 1_790_000_000)
        let folder = directory.appendingPathComponent(wallet.hex)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let topics = log.topics.map { "\"\($0.hexString)\"" }.joined(separator: ",")
        let old = #"{"version":2,"query":"\#(out.query.fingerprint)","covered":[[90000000,100000000]],"head":100000000,"headTimestamp":1790000000,"floor":90000000,"#
            + #""updatedAt":700000000,"logs":[{"a":"\#(log.address.hex)","t":[\#(topics)],"d":"\#(log.data.hexString)","b":100000000,"h":"\#(log.transactionHash.hexString)","i":0,"s":1790000000}]}"#
        try Data(old.utf8).write(to: folder.appendingPathComponent("transfers-out.json"))
        let entry = await HistoryStore(router: router(), directory: directory).cached(out, wallet: wallet)
        XCTAssertEqual(entry.covered, [90_000_000...100_000_000])
        XCTAssertEqual(entry.logs, [log])
        XCTAssertEqual(entry.floor, 90_000_000)
        XCTAssertNil(entry.floorOverride)
        XCTAssertNil(entry.serverEpoch)
        XCTAssertNil(entry.capFloor)
    }

    // MARK: The wallet's history service

    /// A whole read taken in: the first transaction first (the transfer scans' floor follows it, kept apart from the
    /// device's own), then every scan; the snapshot is built from what it added, with no scan. Another wallet's read, or
    /// the metadata alone, adds nothing.
    func testTheServiceTakesInAWholeRead() async throws {
        let kept = KeptBlocks()
        let store = HistoryStore(router: router(), directory: directory)
        let client = LogsStub.rpc()
        let clock = BlockClock(rpc: client, measured: BlockClock.fallbackSecondsPerBlock)
        let service = WalletHistoryService(store: store, swapHistory: SwapHistoryService(rpc: client, clock: clock), clock: clock,
                                           stacks: { DyorCoinRegistry.launchpads(live: .monadMainnet) }, cohorts: DyorCoinRegistry.cohorts(live: .monadMainnet),
                                           knownFirstActivity: { kept.block($0) })
        let token = await store.erasureToken()
        let full = try await read(HistoryDocs.threePages(firstTx: ["state": "found", "block": 100_000_000]))
        LogsStub.install(head: head + 300) { _ in nil }
        let adopted = await service.adopt(full, wallet: wallet, erasureToken: token, epoch: 0)
        XCTAssertEqual(adopted, Set(WalletHistoryScans.ids))
        let serverFirst = await store.serverFirstTransaction(wallet: wallet)
        XCTAssertEqual(serverFirst, 100_000_000)
        XCTAssertNil(kept.block(wallet), "never where the device keeps its own")
        let scans = await service.scans(wallet: wallet, findingFirstTransaction: false)
        XCTAssertEqual(scans.first { $0.id == WalletHistoryScans.transfersInId }?.floor, .earliest(block: 100_000_000, blocks: WalletHistoryScans.transferBlocks))
        let incomingEntry = await store.cached(incoming, wallet: wallet)
        XCTAssertEqual(incomingEntry.floor, 100_000_000, "the first transaction, taken in before the scans")
        let snapshot = await service.cached(wallet: wallet, curves: [], decimals: [:])
        XCTAssertEqual(snapshot.transfersIn.map(\.blockNumber), [103_500_000, 111_000_000])
        XCTAssertEqual(snapshot.anchor?.number, head)

        let other = try await HistoryPagesStub(pages: HistoryDocs.threePages()).client().read(wallet: wallet)
        let none = await service.adopt(other, wallet: HistoryDocs.counterparty, erasureToken: token, epoch: 0)
        XCTAssertEqual(none, [], "another wallet's read")
        var metaScans: [String: [String: Any]] = [:]
        for id in HistoryServerClient.scanOrder { metaScans[id] = HistoryDocs.account(id) }
        let meta = try await HistoryPagesStub(pages: [String?.none: HistoryDocs.data(HistoryDocs.page(scans: metaScans, next: nil))]).client().metadata(wallet: wallet)
        let noneMeta = await service.adopt(meta, wallet: wallet, erasureToken: token, epoch: 0)
        XCTAssertEqual(noneMeta, [], "the metadata alone")
    }

    /// The real document (`HistoryDocs.realPages`) taken in whole: the first transaction, then every scan — transfers-out
    /// from genesis (served whole, nothing left out), transfers-in from its own floor with the hole left a gap — each
    /// without the logs of the newest 1,200 blocks, which are the device's to read.
    func testARealDocumentTakenIn() async throws {
        let store = HistoryStore(router: router(), directory: directory)
        let client = LogsStub.rpc()
        let clock = BlockClock(rpc: client, measured: BlockClock.fallbackSecondsPerBlock)
        let service = WalletHistoryService(store: store, swapHistory: SwapHistoryService(rpc: client, clock: clock), clock: clock,
                                           stacks: { DyorCoinRegistry.launchpads(live: .monadMainnet) }, cohorts: DyorCoinRegistry.cohorts(live: .monadMainnet))
        let token = await store.erasureToken()
        let real = try await HistoryPagesStub(pages: try HistoryDocs.realPages()).client().read(wallet: wallet)
        LogsStub.install(head: head + 300) { _ in nil }
        let adopted = await service.adopt(real, wallet: wallet, erasureToken: token, epoch: 1)
        XCTAssertEqual(adopted, Set(WalletHistoryScans.ids))
        let serverFirst = await store.serverFirstTransaction(wallet: wallet)
        XCTAssertEqual(serverFirst, 103_551_773)
        let outEntry = await store.cached(out, wallet: wallet)
        XCTAssertEqual(outEntry.floorOverride, 0)
        XCTAssertEqual(outEntry.covered, [0...(head - 1_200)])
        XCTAssertEqual(outEntry.logs.count, 2_099, "the one 600 below the head left out")
        XCTAssertEqual(outEntry.serverEpoch, 1)
        let inEntry = await store.cached(incoming, wallet: wallet)
        XCTAssertNil(inEntry.floorOverride)
        XCTAssertEqual(inEntry.floor, windowFloor, "the first transaction is nearer than the window")
        XCTAssertEqual(inEntry.covered, [windowFloor...109_999_999, 110_000_001...(head - 1_200)])
        XCTAssertEqual(inEntry.logs.count, 39)
        XCTAssertEqual(inEntry.unread, 1 + 1_200, "the hole and the margin")
        let snapshot = await service.cached(wallet: wallet, curves: [], decimals: [:])
        XCTAssertEqual(snapshot.transfersIn.count, 39)
        XCTAssertFalse(snapshot.complete, "never complete while a block is unread")
    }

    /// The first transaction only ever moves earlier — the server's (kept in the store) and the device's own lookup, the
    /// floor at the earlier of the two — and nothing is kept once this device's data was erased since the read began; one
    /// the device found nearer is never kept from the server at all.
    func testTheFirstTransactionOnlyMovesEarlier() async throws {
        let store = HistoryStore(router: router(), directory: nil)
        let client = LogsStub.rpc()
        let lookup = LookupGate()
        let service = WalletHistoryService(store: store, swapHistory: SwapHistoryService(rpc: client), clock: BlockClock(rpc: client), stacks: { [] }, cohorts: [],
                                           firstActivity: { _ in await lookup.wait(); return 105_000_000 })
        func floor() async -> HistoryScan.Floor { await service.scans(wallet: wallet, findingFirstTransaction: false)[0].floor }
        func serverFirst() async -> UInt64? { await store.serverFirstTransaction(wallet: wallet) }
        // The device's lookup starts with the first round, and ends after the server's earlier block is taken in.
        _ = await service.scans(wallet: wallet)
        await service.adopt(firstTransaction: 100_000_000, wallet: wallet, erasureToken: 0, epoch: 0)
        let taken = await serverFirst()
        XCTAssertEqual(taken, 100_000_000)
        await lookup.open()
        await service.firstTransactionLookup(wallet)
        let afterLookup = await floor()
        XCTAssertEqual(afterLookup, .earliest(block: 100_000_000, blocks: WalletHistoryScans.transferBlocks), "the earlier of the two: a later lookup never moves it back")

        await service.adopt(firstTransaction: 101_000_000, wallet: wallet, erasureToken: 0, epoch: 0)
        let later = await serverFirst()
        XCTAssertEqual(later, 100_000_000, "later: not taken")
        await service.adopt(firstTransaction: 99_000_000, wallet: wallet, erasureToken: 0, epoch: 0)
        let earlier = await serverFirst()
        XCTAssertEqual(earlier, 99_000_000, "earlier: taken")
        await store.forget(wallet: HistoryDocs.counterparty)
        await service.adopt(firstTransaction: 98_000_000, wallet: wallet, erasureToken: 0, epoch: 0)
        let erased = await serverFirst()
        XCTAssertEqual(erased, 99_000_000, "an erase since the read began: nothing kept")
        let scans = await service.scans(wallet: wallet, findingFirstTransaction: false)
        XCTAssertEqual(scans[0].floor, .earliest(block: 99_000_000, blocks: WalletHistoryScans.transferBlocks))

        // The device's own nearer than the server's: the server's is never kept.
        let other = HistoryStore(router: router(), directory: nil)
        let known = WalletHistoryService(store: other, swapHistory: SwapHistoryService(rpc: client), clock: BlockClock(rpc: client), stacks: { [] }, cohorts: [],
                                         knownFirstActivity: { _ in 100_000_000 })
        await known.adopt(firstTransaction: 100_500_000, wallet: wallet, erasureToken: 0, epoch: 0)
        let nearer = await other.serverFirstTransaction(wallet: wallet)
        XCTAssertNil(nearer)
    }

    /// The server's first transaction is the server's, like what it added to the entries: an epoch reset drops it — in
    /// memory, and on disk as it loads — and so do an erase and a spot check's mismatch (`WalletHistoryService.forget`);
    /// the transfer scans' floor is the device's own again (its lookup's, or the window). In the first cut it was written
    /// where the device keeps its own, for good: a block wrong-early deepened every transfer scan's floor past every
    /// switch — at block 1, some 11,000 requests a scan on rpc2.
    func testTheServersFirstTransactionGoesWithTheServersHistory() async throws {
        let kept = KeptBlocks()
        let client = LogsStub.rpc()
        func service(_ store: HistoryStore) -> WalletHistoryService {
            WalletHistoryService(store: store, swapHistory: SwapHistoryService(rpc: client), clock: BlockClock(rpc: client), stacks: { [] }, cohorts: [],
                                 knownFirstActivity: { kept.block($0) })
        }
        func floor(_ service: WalletHistoryService) async -> HistoryScan.Floor { await service.scans(wallet: wallet, findingFirstTransaction: false)[0].floor }
        let deep = HistoryScan.Floor.earliest(block: 1, blocks: WalletHistoryScans.transferBlocks)

        // Kept on disk with its epoch: read back under the same epoch, dropped as it loads under a higher one.
        let store = HistoryStore(router: router(), directory: directory, epoch: 1)
        let history = service(store)
        await history.adopt(firstTransaction: 1, wallet: wallet, erasureToken: 0, epoch: 1)
        let taken = await floor(history)
        XCTAssertEqual(taken, deep)
        let file = directory.appendingPathComponent(wallet.hex.lowercased()).appendingPathComponent("\(HistoryStore.serverFirstName).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let relaunched = await HistoryStore(router: router(), directory: directory, epoch: 1).serverFirstTransaction(wallet: wallet)
        XCTAssertEqual(relaunched, 1)
        let raised = await HistoryStore(router: router(), directory: directory, epoch: 2).serverFirstTransaction(wallet: wallet)
        XCTAssertNil(raised, "taken in under 1, loaded under 2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // The epoch moves past it in memory: dropped, the window's floor again, and a read under the old epoch refused.
        let memory = HistoryStore(router: router(), directory: nil)
        let inMemory = service(memory)
        await inMemory.adopt(firstTransaction: 1, wallet: wallet, erasureToken: 0, epoch: 0)
        let before = await floor(inMemory)
        XCTAssertEqual(before, deep)
        await memory.apply(epoch: 1)
        let reset = await floor(inMemory)
        XCTAssertEqual(reset, WalletHistoryScans.transferFloor, "the server's gone with the epoch")
        await inMemory.adopt(firstTransaction: 1, wallet: wallet, erasureToken: 0, epoch: 0)
        let stale = await floor(inMemory)
        XCTAssertEqual(stale, WalletHistoryScans.transferFloor, "a read under the old epoch")

        // An erase or a spot check's mismatch: dropped; the device's own found block stands.
        kept.keep(wallet, 105_000_000)
        let distrusted = HistoryStore(router: router(), directory: nil)
        let checked = service(distrusted)
        await checked.adopt(firstTransaction: 1, wallet: wallet, erasureToken: 0, epoch: 0)
        let wrong = await floor(checked)
        XCTAssertEqual(wrong, deep)
        await checked.forget(wallet: wallet)
        let own = await floor(checked)
        XCTAssertEqual(own, .earliest(block: 105_000_000, blocks: WalletHistoryScans.transferBlocks))
        let dropped = await distrusted.serverFirstTransaction(wallet: wallet)
        XCTAssertNil(dropped)
    }

    /// A server filter wider than the scan's — a cohort or stack this build lacks, which `isSubset(of:)` takes on purpose —
    /// has its cap counting logs the scan never matches: it never raises the entry's cap floor nor proves a floor, so the
    /// device's own older logs and coverage stay, and it reads below the server's cap under its own. The scan's own filter,
    /// its lists in another order, raises it as before.
    func testAWiderFiltersCapNeverRaisesTheScans() async throws {
        let moments = HistoryDocs.scan(WalletHistoryScans.momentsId)
        let floor = HistoryDocs.floor(WalletHistoryScans.momentsId)
        // The device read its own history first: a collect at 106,000,000.
        let own = HistoryDocs.log(106_000_000, scan: moments)
        LogsStub.install(head: 107_000_000, logs: [own]) { _ in nil }
        let store = HistoryStore(router: router(), directory: nil)
        let read = await store.refresh(moments, wallet: wallet, budget: LogsBudget(requests: 60, seconds: 30))
        XCTAssertTrue(read.complete)
        XCTAssertEqual(read.logs, [own])

        func server(_ query: LogsQuery) -> ServerScan {
            ServerScan(id: moments.id, kind: .global, defVersion: 1, query: query, fingerprint: query.canonicalFingerprint, floor: floor, capSeen: 106_500_000,
                       from: 106_500_000, to: head, covered: [106_500_000...head], holes: [], head: head, headTimestamp: HistoryDocs.headTimestamp, complete: true,
                       omittedBlocks: [], omittedTruncated: false, finished: true, lowestServedBlock: nil, bounded: false, metaOnly: false,
                       logs: [HistoryDocs.log(109_000_000, scan: moments)], adoptable: [106_500_000...(head - 1_200)])
        }
        let wider = LogsQuery(addresses: moments.query.addresses + [HistoryDocs.counterparty], topics: moments.query.topics)
        XCTAssertTrue(moments.query.isSubset(of: wider))
        let widerTaken = await store.adopt(server(wider), scan: moments, wallet: wallet, erasureToken: 0, epoch: 0)
        let entry = try XCTUnwrap(widerTaken)
        XCTAssertNil(entry.capFloor, "a wider filter's cap is no cap of the scan's")
        XCTAssertEqual(entry.floor, floor)
        XCTAssertEqual(entry.logs.map(\.blockNumber), [106_000_000, 109_000_000], "the device's own older log kept")
        XCTAssertEqual(entry.covered, [floor...(head - 1_200)])

        let reordered = LogsQuery(addresses: Array(moments.query.addresses.reversed()), topics: moments.query.topics.map { $0.map { Array($0.reversed()) } })
        XCTAssertNotEqual(reordered.fingerprint, moments.query.fingerprint)
        let sameTaken = await HistoryStore(router: router(), directory: nil).adopt(server(reordered), scan: moments, wallet: wallet, erasureToken: 0, epoch: 0)
        let same = try XCTUnwrap(sameTaken)
        XCTAssertEqual(same.capFloor, 106_500_000, "the scan's own filter: the same 20,000-log rule")
        XCTAssertEqual(same.floor, 106_500_000)

        // A transfer scan: the cap proves a floor for the scan's own filter only.
        let capped = try await self.read(HistoryDocs.threePages(capTwo: 50_000_000))
        let outServer = try XCTUnwrap(capped.scan(out))
        XCTAssertEqual(HistoryStore.provedFloor(outServer, for: out), 50_000_000)
        let narrower = HistoryScan(id: out.id, query: LogsQuery(addresses: [HistoryDocs.token], topics: out.query.topics), floor: out.floor)
        XCTAssertTrue(narrower.query.isSubset(of: outServer.query))
        XCTAssertNil(HistoryStore.provedFloor(outServer, for: narrower), "logs of the scan below a wider filter's cap may be gone")
        let narrowTaken = await HistoryStore(router: router(), directory: nil).adopt(outServer, scan: narrower, wallet: wallet, erasureToken: 0, epoch: 0)
        let narrow = try XCTUnwrap(narrowTaken)
        XCTAssertNil(narrow.capFloor)
        XCTAssertNil(narrow.floorOverride)
        XCTAssertEqual(narrow.floor, windowFloor)
    }
}

/// Holds a stub's answer until the test opens it, and says when one is waiting.
final class HoldGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var waiting = false

    var entered: Bool {
        condition.lock(); defer { condition.unlock() }
        return waiting
    }

    func enterAndWait() {
        condition.lock()
        waiting = true
        while !isOpen { condition.wait() }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

/// First-transaction blocks kept as the app keeps them in UserDefaults: only ever earlier.
final class KeptBlocks: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [Address: UInt64] = [:]

    func block(_ wallet: Address) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return blocks[wallet]
    }

    func keep(_ wallet: Address, _ block: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if blocks[wallet].map({ block < $0 }) ?? true { blocks[wallet] = block }
    }
}

/// Holds a first-transaction lookup until the test opens it.
actor LookupGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
