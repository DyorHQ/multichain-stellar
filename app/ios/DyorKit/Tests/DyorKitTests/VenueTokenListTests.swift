import BigInt
import XCTest
@testable import DyorKit

/// The venue list as the app holds it (`VenueTokenList`): read from the store once and kept in memory, so the swap
/// picker's search never decodes 1.8 MB of JSON on the main thread (four times a render, 0.1–0.15 s each); saved only
/// past a segment read in full, in the format build 16 reads.
@MainActor
final class VenueTokenListTests: XCTestCase {
    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    func testTheListIsReadOnceKeptInMemoryAndSavedOnlyPastASegmentReadInFull() async throws {
        VenueFixture.installMetadata()
        // Build 16's list, and no checkpoint of build 17's: the history is read once more.
        let store = MemoryStore(list: [VenueFixture.token(50, symbol: "T50")], checkpoint: 0)
        let gap = Flag(true)
        // T3 on Uniswap v3 is read in the second segment; its range past block 8,000,000 isn't answered, a gap.
        LogsStub.install(head: 12_000_000, logs: [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(3, at: 7_000_000), VenueFixture.pool(4, at: 11_000_000)]) { range in
            gap.on && range.contains(8_000_000) ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let list = store.list()
        list.refresh()
        await list.finished()
        XCTAssertEqual(list.tokens.map(\.symbol), ["T50", "T1", "T3"], "what the segment read in part found is shown")
        XCTAssertEqual(list.checkpoint, 4_999_999)
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999], "saved past the first segment only")
        XCTAssertEqual(store.writes.last?.symbols, ["T50", "T1"])
        XCTAssertEqual(store.reads, 1)

        gap.set(false)
        list.refresh()
        await list.finished()
        XCTAssertEqual(list.tokens.map(\.symbol), ["T50", "T1", "T3", "T4"])
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999, 9_999_999, 11_999_900])
        XCTAssertEqual(store.reads, 1, "the store is read once")
        // Build 16 reads what is saved: a JSON array of `Token`.
        let saved = try JSONDecoder().decode([Token].self, from: try XCTUnwrap(store.data))
        XCTAssertEqual(saved, list.tokens)
    }

    /// The finding: a run that ended short (a gap, the head unread, the app suspended mid-read) was retried only by a cold
    /// launch. A return to the app runs it again, after a pause that doubles with each short run in a row; a run that read
    /// to the head isn't repeated.
    func testARunThatEndedShortRunsAgainOnAReturnAfterAPause() async {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        let clock = TestClock()
        let gap = Flag(true)
        LogsStub.install(head: 12_000_000, logs: [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(4, at: 11_000_000)]) { range in
            gap.on && range.contains(8_000_000) ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let list = store.list(now: { clock.now })
        list.refresh()
        await list.finished()
        XCTAssertEqual(list.shortRuns, 1)
        XCTAssertEqual(list.checkpoint, 4_999_999)

        list.resume()
        XCTAssertFalse(list.isRefreshing, "30 s first")
        clock.advance(31)
        list.resume()
        XCTAssertTrue(list.isRefreshing)
        await list.finished()
        XCTAssertEqual(list.shortRuns, 2, "still short")
        clock.advance(31)
        list.resume()
        XCTAssertFalse(list.isRefreshing, "a minute after the second")
        clock.advance(30)
        gap.set(false)
        list.resume()
        await list.finished()
        XCTAssertEqual(list.shortRuns, 0)
        XCTAssertEqual(list.checkpoint, 11_999_900)
        XCTAssertEqual(list.tokens.map(\.symbol), ["T1", "T4"])

        clock.advance(3_600)
        list.resume()
        XCTAssertFalse(list.isRefreshing, "read to the head: nothing to resume")
        XCTAssertEqual((1...8).map(VenueTokenList.retryPause(afterShortRuns:)), [30, 60, 120, 240, 480, 960, 1_800, 1_800])
    }

    /// The finding: Delete Account erased UserDefaults while the refill ran, and the refill's next save wrote
    /// `venueTokens.v1` back, so App Lock's default took the next launch for an install from before it and started OFF
    /// (R4). `stop()`, before the erase, cancels the run, and nothing is saved after it — not even a save already on its
    /// way — nor run again in this process.
    func testNothingIsSavedOrRunAfterStop() async throws {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        LogsStub.install(head: 20_000_000, logs: [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(4, at: 6_000_000), VenueFixture.pool(7, at: 11_000_000)],
                         latency: 0.03) { _ in nil }
        let list = store.list()
        list.refresh()
        let deadline = Date().addingTimeInterval(10)
        while store.writes.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999])
        list.stop()
        let requestsAtStop = LogsStub.requests()
        XCTAssertFalse(list.isRefreshing)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999], "no save after stop")
        XCTAssertLessThanOrEqual(LogsStub.requests(), requestsAtStop + 1, "the run is cancelled: the request under way at most")
        list.refresh()
        list.resume()
        XCTAssertFalse(list.isRefreshing, "nothing runs again")
        XCTAssertTrue(list.isStopped)
        XCTAssertEqual(list.tokens.map(\.symbol), ["T1"], "the list in memory stays for search")
    }

    /// The finding: the picker's "still loading" was `checkpoint == 0` at the start of a run, then whatever the last save
    /// said: a refill resumed from part-way said nothing until its first segment, one whose head couldn't be read said
    /// nothing at all, and a run that ended short kept saying it though nothing ran. It now follows the list: short of the
    /// head the last run read towards (or never read), and nothing after `stop()`.
    func testCatchingUpFollowsWhetherTheListIsShortOfTheChain() async {
        VenueFixture.installMetadata()
        let pools = [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(4, at: 51_000_000)]
        // A fresh install: nothing read, so a search may miss a token, from before the head is known.
        LogsStub.install(head: 0, logs: pools) { _ in nil }
        let fresh = MemoryStore(list: [], checkpoint: 0).list()
        XCTAssertFalse(fresh.isCatchingUp, "not before the store is read")
        fresh.refresh()
        await fresh.finished()
        XCTAssertNil(fresh.head, "the head couldn't be read")
        XCTAssertTrue(fresh.isCatchingUp)
        // Stopped (Delete Account): nothing reads on, so nothing is said.
        fresh.stop()
        XCTAssertFalse(fresh.isCatchingUp)

        // A refill that stopped part-way, at 50M: said once the run knows the head, and while it ends short.
        let gap = Flag(true)
        LogsStub.install(head: 60_000_000, logs: pools) { range in gap.on && range.contains(52_000_000) ? .error(code: -32062, message: "Block range is too large") : nil }
        let partWay = MemoryStore(list: [VenueFixture.token(1, symbol: "T1")], checkpoint: 49_999_999).list()
        partWay.refresh()
        await partWay.finished()
        XCTAssertEqual(partWay.checkpoint, 49_999_999)
        XCTAssertEqual(partWay.head, 60_000_000)
        XCTAssertTrue(partWay.isCatchingUp, "short of the head, to be read on at the next return")
        gap.set(false)
        partWay.refresh()
        await partWay.finished()
        XCTAssertEqual(partWay.checkpoint, 59_999_900)
        XCTAssertFalse(partWay.isCatchingUp, "read to the head")
    }

    /// The re-review's finding: "still loading" was missing while the first run read the store (a search then finds
    /// nothing, and said nothing), and for a list an earlier launch left half-built, relaunched offline (no head read, and
    /// a checkpoint above 0). Before the head is read, the list is compared with a block the chain is known to have passed.
    func testCatchingUpWhileTheStoreIsReadAndOfflineForAHalfBuiltList() async {
        VenueFixture.installMetadata()
        LogsStub.install(head: 0) { _ in nil }
        let service = VenueTokensService(logsRPC: LogsStub.rpc(), multicall: Multicall(rpc: MomentsChainStub.rpc()))
        let slow = VenueTokenList(service: service, logos: { [:] }, read: {
            Thread.sleep(forTimeInterval: 0.3)
            return VenueTokenList.Stored(list: nil, checkpoint: 0)
        }, write: { _, _, _ in true })
        XCTAssertFalse(slow.isCatchingUp, "nothing reads yet")
        slow.refresh()
        XCTAssertFalse(slow.isLoaded)
        XCTAssertTrue(slow.isCatchingUp, "the store is being read")
        await slow.finished()

        for (checkpoint, short) in [(UInt64(49_999_999), true), (VenueTokensService.target(head: VenueTokensService.knownHeight), false)] {
            let offline = MemoryStore(list: [VenueFixture.token(1, symbol: "T1")], checkpoint: checkpoint).list()
            offline.refresh()
            await offline.finished()
            XCTAssertNil(offline.head, "the head couldn't be read")
            XCTAssertEqual(offline.isCatchingUp, short, "checkpoint \(checkpoint)")
        }
    }

    /// A list saved but unreadable (or missing) while the checkpoint is above 0 is read again from genesis: its
    /// checkpoint would skip every token it held. A readable list's long symbols and names are capped as a new read's are.
    func testAListThatCantBeReadBackIsReadAgainFromGenesis() async throws {
        VenueFixture.installMetadata()
        for data in [Data("not a list".utf8), nil] {
            LogsStub.install(head: 60_000_000, logs: [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(4, at: 51_000_000)]) { _ in nil }
            let store = MemoryStore(data: data, checkpoint: 49_999_999)
            let list = store.list()
            list.refresh()
            await list.finished()
            XCTAssertEqual(LogsStub.queries().map(\.from).min(), 0, "read from genesis")
            XCTAssertEqual(list.tokens.map(\.symbol), ["T1", "T4"])
            XCTAssertEqual(store.writes.first?.checkpoint, 4_999_999, "the store starts over too")
            XCTAssertEqual(list.checkpoint, 59_999_900)
        }

        let long = Token(address: VenueFixture.address(9), symbol: String(repeating: "S", count: 500), name: String(repeating: "N", count: 500), decimals: 18)
        let decoded = VenueTokenList.decode(.init(list: try JSONEncoder().encode([long]), checkpoint: 7))
        XCTAssertEqual(decoded.checkpoint, 7)
        XCTAssertEqual(decoded.tokens.map(\.symbol.count), [32])
        XCTAssertEqual(decoded.tokens.map(\.name.count), [64])
    }

    /// What a run read with no readable symbol is kept for the runs after it: the segment it left short is read again
    /// without reading that address again (it used to pay for it at every run).
    func testWhatARunDroppedIsNotReadAgainByTheNext() async {
        let bad = VenueFixture.address(3)
        let answer: MomentsChainStub.Answer = { to, data in
            let selector = data.prefix(4)
            guard to != bad else { return nil }
            if selector == ABI.selector("symbol()") || selector == ABI.selector("name()") { return try! ABI.encode([.string("T\(to.data.last ?? 0)")], "string") }
            return selector == ABI.selector("decimals()") ? try! ABI.encode([.uint(18)], "uint8") : nil
        }
        MomentsChainStub.install(answer)
        let gap = Flag(true)
        // The token with no symbol has a Uniswap v3 pool in the second segment; that venue's range past block 8,000,000
        // isn't answered, so the segment is read again.
        LogsStub.install(head: 12_000_000, logs: [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(3, at: 6_000_000), VenueFixture.pool(4, at: 7_000_000)]) { range in
            gap.on && range.contains(8_000_000) ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let list = MemoryStore(list: [], checkpoint: 0).list()
        list.refresh()
        await list.finished()
        XCTAssertEqual(list.checkpoint, 4_999_999)
        XCTAssertFalse(MomentsChainStub.calls().filter { $0.to == bad }.isEmpty, "read, and dropped")

        MomentsChainStub.install(answer)
        gap.set(false)
        list.refresh()
        await list.finished()
        XCTAssertEqual(list.checkpoint, 11_999_900)
        XCTAssertEqual(list.tokens.map(\.symbol), ["T1", "T4"])
        XCTAssertTrue(MomentsChainStub.calls().filter { $0.to == bad }.isEmpty, "not read again")
    }

    /// The V1 final check's finding (P3): what a run dropped lived only in memory, so a segment that needs more reads again
    /// than one run allows (over about 196 addresses whose `symbol()` reverts: `VenueTokensService.metadataRereads`) was
    /// read from nothing again at every launch, never completed, and held every segment after it. It is saved with the
    /// checkpoint, and the next launch reads on from it.
    func testWhatARunDroppedIsKeptAcrossLaunches() async throws {
        let bad = (1...250).map(VenueFixture.spam)
        let badSet = Set(bad)
        let answer: MomentsChainStub.Answer = { to, data in
            guard !badSet.contains(to) else { return nil }
            let selector = data.prefix(4)
            if selector == ABI.selector("symbol()") || selector == ABI.selector("name()") { return try! ABI.encode([.string("T\(to.data.last ?? 0)")], "string") }
            return selector == ABI.selector("decimals()") ? try! ABI.encode([.uint(18)], "uint8") : nil
        }
        LogsStub.install(head: 1_000, logs: [VenueFixture.pool(1, at: 5)] + bad.enumerated().map { VenueFixture.spamPool($1, at: UInt64($0) + 10) }) { _ in nil }
        let store = MemoryStore(list: [], checkpoint: 0)

        // The first launch drops what its budget lets it read again, leaves the rest unread, and saves what it dropped with
        // the checkpoint, which stays.
        MomentsChainStub.install(answer)
        let first = store.list()
        first.refresh()
        await first.finished()
        XCTAssertEqual(first.checkpoint, 0)
        XCTAssertEqual(first.shortRuns, 1)
        let dropped = Set(store.dropped)
        XCTAssertEqual(dropped.count, 197, "three reads in full, 46 of the fourth, and the last address, read on its own")
        XCTAssertTrue(dropped.isSubset(of: badSet))
        XCTAssertEqual(store.writes.map(\.checkpoint), [0], "saved for what it dropped, the checkpoint where it was")

        // A relaunch: a new list on the same store reads on from what the first launch dropped, and reads the segment in full.
        MomentsChainStub.install(answer)
        let second = store.list()
        second.refresh()
        await second.finished()
        XCTAssertTrue(MomentsChainStub.calls().allSatisfy { !dropped.contains($0.to) }, "what the first launch dropped isn't read again")
        XCTAssertEqual(second.checkpoint, 900)
        XCTAssertEqual(second.tokens.map(\.symbol), ["T1"])
        XCTAssertEqual(store.writes.map(\.checkpoint), [0, 900])
        XCTAssertEqual(Set(store.dropped), badSet)
    }

    /// What runs dropped is stored as 20 bytes an address, at most `maxStoredDropped` (100 KB), the newest first: past it,
    /// the oldest go. It is kept when the list starts over from genesis.
    func testWhatRunsDroppedIsStoredBoundedNewestFirst() {
        let old = (1...4_990).map(VenueFixture.spam)
        let new = (5_001...5_020).map(VenueFixture.spam)
        let stored = VenueTokenList.storedDropped(Set(old), after: [])
        XCTAssertEqual(Set(stored), Set(old))
        let next = VenueTokenList.storedDropped(Set(new), after: stored)
        let again = VenueTokenList.storedDropped(Set(old + new), after: stored)
        XCTAssertEqual(Set(again.prefix(20)), Set(new), "what the store holds isn't new")
        XCTAssertEqual(Array(again.dropFirst(20)), Array(next.dropFirst(20)))
        XCTAssertEqual(next.count, VenueTokenList.maxStoredDropped)
        XCTAssertEqual(Set(next.prefix(20)), Set(new), "the newest first")
        XCTAssertEqual(Array(next.dropFirst(20)), Array(stored.prefix(4_980)), "the oldest go")
        let data = VenueTokenList.encode(dropped: next)
        XCTAssertEqual(data.count, 100_000)
        XCTAssertEqual(VenueTokenList.decode(dropped: data), next)
        XCTAssertEqual(VenueTokenList.decode(dropped: Data([1, 2, 3])), [])
        XCTAssertEqual(VenueTokenList.decode(dropped: nil), [])
        XCTAssertEqual(VenueTokenList.decode(.init(list: nil, checkpoint: 7, dropped: data)).dropped, next, "kept when the list starts over")
    }

    /// The V1 final check's finding: a save the store declined (UserDefaults refuses a value past its ceiling, and
    /// `VenueTokenStore.write` then saves no checkpoint) was taken as saved, so it wasn't tried again until the checkpoint
    /// moved on. Only a save the store took counts.
    func testASaveTheStoreDeclinedIsTriedAgain() async {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        store.refuseWrites(true)
        let gap = Flag(true)
        // The second segment is read in part: its checkpoint stays that of the first.
        LogsStub.install(head: 12_000_000, logs: [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(4, at: 11_000_000)]) { range in
            gap.on && range.contains(8_000_000) ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let list = store.list()
        list.refresh()
        await list.finished()
        XCTAssertEqual(list.checkpoint, 4_999_999)
        XCTAssertEqual(store.attempts, [4_999_999, 4_999_999], "declined, so tried again with the segment read in part")
        XCTAssertTrue(store.writes.isEmpty)

        store.refuseWrites(false)
        gap.set(false)
        list.refresh()
        await list.finished()
        XCTAssertEqual(store.writes.map(\.checkpoint), [9_999_999, 11_999_900])
        XCTAssertEqual(store.writes.last?.symbols, ["T1", "T4"])
    }

    func testOneRunAtATime() async {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        LogsStub.install(head: 1_000, logs: [VenueFixture.pool(1, at: 10)], latency: 0.01) { _ in nil }
        let list = store.list()
        list.refresh()
        list.refresh()
        XCTAssertTrue(list.isRefreshing)
        list.refresh()
        await list.finished()
        XCTAssertFalse(list.isRefreshing)
        XCTAssertEqual(LogsStub.queries().count, 3, "one range for each venue, once")
        XCTAssertEqual(list.tokens.map(\.symbol), ["T1"])
    }

    /// Four segments to the head, one pool in each.
    private let fourSegments = [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(4, at: 6_000_000), VenueFixture.pool(7, at: 11_000_000),
                                VenueFixture.pool(10, at: 16_000_000)]
    private let alice = Address(literal: "0x00000000000000000000000000000000000a11ce")
    private let bob = Address(literal: "0x0000000000000000000000000000000000000b0b")
    private let carol = Address(literal: "0x00000000000000000000000000000000000ca201")

    /// Waits until the stub holds a request (`LogsStub.install(holding:)`): the run reads there, and goes no further until
    /// `LogsStub.release()`, however fast or slow the machine is.
    private func heldAtStub() async throws {
        let deadline = Date().addingTimeInterval(10)
        while LogsStub.held() == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(LogsStub.held(), 1)
    }

    /// The speed review's finding (2026-10-09): the run started during onboarding and read on, to the head, through a
    /// fresh install's first history fill, at the same gate. While a wallet's history fills in for the first time, the run
    /// is cancelled at once; what it read in full stays, its checkpoint at a segment's end, and once the history is read
    /// the next run reads on from there. A pause is no run that ended short: no wait before the next. The run is held at
    /// the stub in its second segment, so the pause comes there whatever the machine's pace.
    func testARunPausesWhileAWalletsHistoryFillsInForTheFirstTimeAndReadsOnFromItsCheckpoint() async throws {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        LogsStub.install(head: 20_000_000, logs: fourSegments, holding: { $0.from >= 5_000_000 }) { _ in nil }
        let list = store.list()
        list.follow(wallet: alice, historyFilling: false)
        XCTAssertTrue(list.isRefreshing)
        try await heldAtStub()
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999])

        // Another wallet, its history filling in for the first time: the run is cancelled at once.
        let requestsAtPause = LogsStub.requests()
        list.follow(wallet: bob, historyFilling: true)
        XCTAssertTrue(list.isHeld)
        LogsStub.release()
        await list.finished()
        XCTAssertFalse(list.isRefreshing)
        XCTAssertEqual(LogsStub.requests(), requestsAtPause, "nothing asked past the request it was reading")
        XCTAssertEqual(list.shortRuns, 0, "a pause is no run that ended short")
        XCTAssertEqual(list.checkpoint, 4_999_999)
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999])
        XCTAssertEqual(list.tokens.map(\.symbol), ["T1"])
        XCTAssertTrue(list.isCatchingUp, "short of the chain, and says so")
        // Nothing reads while the history fills in: not another refresh, nor a return to the app.
        list.refresh()
        list.resume()
        XCTAssertFalse(list.isRefreshing)
        XCTAssertEqual(LogsStub.requests(), requestsAtPause)

        // The history read: the next run reads on from the checkpoint, not from genesis.
        LogsStub.install(head: 20_000_000, logs: fourSegments) { _ in nil }
        list.follow(wallet: bob, historyFilling: false)
        XCTAssertFalse(list.isHeld)
        XCTAssertTrue(list.isRefreshing)
        await list.finished()
        XCTAssertEqual(LogsStub.queries().map(\.from).min(), 5_000_000, "from the segment after the checkpoint")
        XCTAssertEqual(list.checkpoint, 19_999_900)
        XCTAssertEqual(list.tokens.map(\.symbol), ["T1", "T4", "T7", "T10"])
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999, 9_999_999, 14_999_999, 19_999_900])
        XCTAssertEqual(list.shortRuns, 0)
        XCTAssertFalse(list.isCatchingUp)
    }

    /// The speed review's finding (2026-10-09): every flip of the history to "filling in" — a round left with a gap, the
    /// transfer scans reading further back once the wallet's first transaction is found — cancelled the run, and the
    /// segment it was reading, up to three venues' requests, was read again. Once a wallet's history has been read, its
    /// filling in again holds nothing: the run under way reads on (the gate already puts it behind every history round).
    func testAWalletsHistoryFillingInAgainNeverPausesTheRun() async throws {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        LogsStub.install(head: 20_000_000, logs: fourSegments, holding: { $0.from >= 5_000_000 }) { _ in nil }
        let list = store.list()
        list.follow(wallet: alice, historyFilling: true)
        XCTAssertTrue(list.isHeld, "the first fill")
        XCTAssertFalse(list.isRefreshing)
        list.follow(wallet: alice, historyFilling: false)
        XCTAssertTrue(list.isRefreshing)
        try await heldAtStub()

        list.follow(wallet: alice, historyFilling: true)
        XCTAssertFalse(list.isHeld)
        XCTAssertTrue(list.isRefreshing, "not cancelled")
        LogsStub.release()
        await list.finished()
        XCTAssertEqual(list.checkpoint, 19_999_900)
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999, 9_999_999, 14_999_999, 19_999_900], "every segment read once")
        XCTAssertEqual(LogsStub.queries().filter { $0.from == 5_000_000 }.count, 3, "the second segment's three venues, once each")
    }

    /// A pause lifted before the run it cancelled has ended (the `refresh` it brings finds that run still going): the
    /// cancelled run starts the next as it ends, rather than leaving the list unread until the next change.
    func testAPauseLiftedWhileTheCancelledRunEndsReadsOnAtOnce() async throws {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        LogsStub.install(head: 20_000_000, logs: fourSegments, holding: { $0.from >= 5_000_000 }) { _ in nil }
        let list = store.list()
        list.follow(wallet: alice, historyFilling: false)
        try await heldAtStub()
        list.follow(wallet: bob, historyFilling: true)
        list.follow(wallet: bob, historyFilling: false)
        XCTAssertTrue(list.isRefreshing, "the cancelled run is still ending")
        LogsStub.release()
        await list.finished()
        XCTAssertTrue(list.isRefreshing, "the next run started as the cancelled one ended")
        await list.finished()
        XCTAssertFalse(list.isRefreshing)
        XCTAssertEqual(list.checkpoint, 19_999_900)
        XCTAssertEqual(list.tokens.map(\.symbol), ["T1", "T4", "T7", "T10"])
        XCTAssertEqual(list.shortRuns, 0)

        // Paused and lifted before the run it cancelled ends, then paused again (a third wallet's first fill): the
        // cancelled run ends, and nothing starts.
        let again = MemoryStore(list: [], checkpoint: 0)
        LogsStub.install(head: 20_000_000, logs: fourSegments, holding: { $0.from >= 5_000_000 }) { _ in nil }
        let paused = again.list()
        paused.follow(wallet: alice, historyFilling: false)
        try await heldAtStub()
        paused.follow(wallet: bob, historyFilling: true)
        paused.follow(wallet: bob, historyFilling: false)
        paused.follow(wallet: carol, historyFilling: true)
        LogsStub.release()
        await paused.finished()
        XCTAssertFalse(paused.isRefreshing)
        XCTAssertEqual(paused.checkpoint, 4_999_999)
        XCTAssertEqual(paused.shortRuns, 0)
    }

    /// A hold lifted after a run that ended short doesn't cut that run's pause short: the run after it waits it out, as a
    /// return to the app does (`resume`), so an endpoint that is down isn't asked again at every change of the history.
    func testALiftedHoldWaitsOutAShortRunsPause() async {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        let clock = TestClock()
        let gap = Flag(true)
        LogsStub.install(head: 12_000_000, logs: [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(4, at: 11_000_000)]) { range in
            gap.on && range.contains(8_000_000) ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let list = store.list(now: { clock.now })
        list.follow(wallet: alice, historyFilling: false)
        await list.finished()
        XCTAssertEqual(list.shortRuns, 1)

        list.follow(wallet: bob, historyFilling: true)
        list.follow(wallet: bob, historyFilling: false)
        XCTAssertFalse(list.isRefreshing, "30 s first")
        clock.advance(31)
        gap.set(false)
        list.follow(wallet: bob, historyFilling: false)
        XCTAssertTrue(list.isRefreshing)
        await list.finished()
        XCTAssertEqual(list.shortRuns, 0)
        XCTAssertEqual(list.checkpoint, 11_999_900)
    }

    /// The speed review's finding (2026-10-09): a fresh install read the venues from genesis (about 5,600 requests) during
    /// onboarding, with no wallet signed in. A list that holds nothing read now waits for a sign-in: the store is read,
    /// nothing else (search has the curated and Kuru lists meanwhile). A list read before — in part, with no token yet, or
    /// build 16's — reads on with no wallet signed in, whatever the history's empty stand-in says.
    func testWithNoWalletSignedInOnlyAListReadBeforeReadsOn() async throws {
        VenueFixture.installMetadata()
        let pools = [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(4, at: 11_000_000)]
        LogsStub.install(head: 12_000_000, logs: pools) { _ in nil }
        let store = MemoryStore(list: [], checkpoint: 0)
        let fresh = store.list()
        fresh.follow(wallet: nil, historyFilling: true)
        XCTAssertTrue(fresh.isRefreshing, "the store is read first, to know")
        await fresh.finished()
        XCTAssertEqual(store.reads, 1)
        XCTAssertEqual(LogsStub.requests(), 0, "nothing else: not even the head")
        XCTAssertTrue(fresh.isHeld)
        XCTAssertFalse(fresh.isRefreshing)
        XCTAssertEqual(fresh.shortRuns, 0, "a run that waits is no run that ended short")
        XCTAssertTrue(fresh.isCatchingUp, "a search may miss a token")
        fresh.refresh()
        fresh.resume()
        XCTAssertFalse(fresh.isRefreshing)
        XCTAssertEqual(LogsStub.requests(), 0)

        // A sign-in: the read from genesis waits for the wallet's history, then starts.
        fresh.follow(wallet: alice, historyFilling: true)
        XCTAssertFalse(fresh.isRefreshing)
        fresh.follow(wallet: alice, historyFilling: false)
        XCTAssertTrue(fresh.isRefreshing)
        await fresh.finished()
        XCTAssertEqual(LogsStub.queries().map(\.from).min(), 0, "from genesis")
        XCTAssertEqual(fresh.checkpoint, 11_999_900)
        XCTAssertEqual(fresh.tokens.map(\.symbol), ["T1", "T4"])

        // Read in part with a token, read in part with none yet (the first segments hold no pool), and build 16's list with
        // no checkpoint of this build's: each reads on from its checkpoint.
        let readBefore: [(tokens: [Token], checkpoint: UInt64, after: [String])] = [([VenueFixture.token(1, symbol: "T1")], 4_999_999, ["T1", "T4"]),
                                                                                   ([], 4_999_999, ["T4"]),
                                                                                   ([VenueFixture.token(1, symbol: "T1")], 0, ["T1", "T4"])]
        for (tokens, checkpoint, after) in readBefore {
            LogsStub.install(head: 12_000_000, logs: pools) { _ in nil }
            let list = MemoryStore(list: tokens, checkpoint: checkpoint).list()
            await list.load()
            list.follow(wallet: nil, historyFilling: true)
            XCTAssertFalse(list.isHeld, "checkpoint \(checkpoint), \(tokens.count) tokens")
            XCTAssertTrue(list.isRefreshing)
            await list.finished()
            XCTAssertEqual(LogsStub.queries().map(\.from).min(), checkpoint == 0 ? 0 : checkpoint + 1)
            XCTAssertEqual(list.checkpoint, 11_999_900)
            XCTAssertEqual(list.tokens.map(\.symbol), after)
        }
    }

    /// A sign-out while a run reads from genesis, before its first segment is read in full: the list still holds nothing
    /// read, so the run is cancelled, as no read from genesis starts with no wallet signed in; nothing is saved, and it is
    /// no run that ended short. The run is held at the stub in its first request, so the sign-out comes there.
    func testASignOutBeforeTheFirstSegmentIsReadCancelsTheReadFromGenesis() async throws {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        LogsStub.install(head: 20_000_000, logs: fourSegments, holding: { _ in true }) { _ in nil }
        let list = store.list()
        await list.load()
        list.follow(wallet: alice, historyFilling: false)
        try await heldAtStub()
        list.follow(wallet: nil, historyFilling: true)
        XCTAssertTrue(list.isHeld)
        LogsStub.release()
        await list.finished()
        XCTAssertFalse(list.isRefreshing)
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(list.checkpoint, 0)
        XCTAssertEqual(list.shortRuns, 0)
    }

    /// The store is read once however many ask while it is read: a run that starts while `load` reads it (as the app's
    /// launch can) waits for that read, where each decoded the 1.8 MB list.
    func testTheStoreIsReadOnceWhenARunStartsWhileItIsRead() async {
        VenueFixture.installMetadata()
        LogsStub.install(head: 12_000_000) { _ in nil }
        let store = MemoryStore(list: [VenueFixture.token(1, symbol: "T1")], checkpoint: 11_999_900)
        let list = store.list()
        list.refresh()
        await list.load()
        await list.finished()
        await list.load()
        XCTAssertEqual(store.reads, 1)
        XCTAssertEqual(list.tokens.map(\.symbol), ["T1"])
        XCTAssertEqual(list.checkpoint, 11_999_900)
        XCTAssertFalse(list.isCatchingUp)
    }

    /// `stop()` (Delete Account, Forget This Device) still ends everything while the run waits or reads: no hold lifted
    /// after it starts one, and the run a pause cancelled starts none as it ends, so nothing is saved after the erase
    /// (R4).
    func testNothingRunsAfterStopWhateverTheAppSays() async throws {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        LogsStub.install(head: 20_000_000, logs: fourSegments, holding: { $0.from >= 5_000_000 }) { _ in nil }
        let list = store.list()
        list.follow(wallet: alice, historyFilling: false)
        try await heldAtStub()
        list.follow(wallet: bob, historyFilling: true)
        list.stop()
        list.follow(wallet: bob, historyFilling: false)
        XCTAssertFalse(list.isRefreshing)
        LogsStub.release()
        await list.finished()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(list.isRefreshing, "the cancelled run starts nothing as it ends")
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999], "no save after stop")
        XCTAssertFalse(list.isCatchingUp)
    }
}

/// Pools and token metadata on the stubs, as `VenueTokensTests` has them.
enum VenueFixture {
    static let created = ABI.eventTopic("PoolCreated(address,address,uint24,int24,address)")
    static let initialized = ABI.eventTopic("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)")

    static func address(_ n: UInt8) -> Address { Address(data: Data(repeating: 0, count: 19) + Data([n]))! }

    static func token(_ n: UInt8, symbol: String) -> Token { Token(address: address(n), symbol: symbol, name: symbol, decimals: 18) }

    /// A pool for token `n` against WMON at `block`: on Uniswap v3, Monday Trade or Uniswap v4 by `n % 3`.
    static func pool(_ n: UInt8, at block: UInt64) -> Log {
        let word = { (address: Address) in address.data.leftPadded(to: 32) }
        let hash = Data(repeating: n, count: 32)
        switch n % 3 {
        case 0: return Log(address: Uniswap.v3Factory, topics: [created, word(address(n)), word(Monad.wmon), BigUInt(3000).word], data: Data(count: 64),
                           blockNumber: block, transactionHash: hash, logIndex: 0)
        case 1: return Log(address: MondayTrade.factory, topics: [created, word(Monad.wmon), word(address(n)), BigUInt(3000).word], data: Data(count: 64),
                           blockNumber: block, transactionHash: hash, logIndex: 0)
        default: return Log(address: Uniswap.poolManager, topics: [initialized, hash, word(Monad.native), word(address(n))], data: Data(count: 160),
                            blockNumber: block, transactionHash: hash, logIndex: 0)
        }
    }

    /// Address `n` of many (up to 65,535) as anyone can put in Uniswap v4 pools (`initialize` takes any pair).
    static func spam(_ n: Int) -> Address { Address(data: Data(repeating: 0, count: 16) + Data([0x5b, 0xad, UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]))! }

    /// A Uniswap v4 pool for `token` against MON at `block`.
    static func spamPool(_ token: Address, at block: UInt64) -> Log {
        let word = { (address: Address) in address.data.leftPadded(to: 32) }
        let id = Data(repeating: 0, count: 24) + BigUInt(block).word.suffix(8)
        return Log(address: Uniswap.poolManager, topics: [initialized, id, word(Monad.native), word(token)], data: Data(count: 160),
                   blockNumber: block, transactionHash: id, logIndex: 0)
    }

    /// Every token answers its symbol and name ("T" and its number) and 18 decimals.
    static func installMetadata() {
        MomentsChainStub.install { to, data in
            let selector = data.prefix(4)
            if selector == ABI.selector("symbol()") || selector == ABI.selector("name()") { return try! ABI.encode([.string("T\(to.data.last ?? 0)")], "string") }
            if selector == ABI.selector("decimals()") { return try! ABI.encode([.uint(18)], "uint8") }
            return nil
        }
    }
}

/// A store in memory: what it holds, how often it was read, and every write, decoded.
final class MemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VenueTokenList.Stored
    private var readCount = 0
    private var written: [(symbols: [String], checkpoint: UInt64)] = []
    private var attempted: [UInt64] = []
    private var refusing = false

    init(list: [Token]?, checkpoint: UInt64) {
        stored = VenueTokenList.Stored(list: list.flatMap { try? JSONEncoder().encode($0) }, checkpoint: checkpoint)
    }

    init(data: Data?, checkpoint: UInt64) {
        stored = VenueTokenList.Stored(list: data, checkpoint: checkpoint)
    }

    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    var writes: [(symbols: [String], checkpoint: UInt64)] { lock.lock(); defer { lock.unlock() }; return written }
    var data: Data? { lock.lock(); defer { lock.unlock() }; return stored.list }
    /// What runs dropped, as saved.
    var dropped: [Address] { lock.lock(); defer { lock.unlock() }; return VenueTokenList.decode(dropped: stored.dropped) }
    /// The checkpoint of every write asked, taken or declined.
    var attempts: [UInt64] { lock.lock(); defer { lock.unlock() }; return attempted }

    /// Declines every write while `refuse`, as UserDefaults refuses a value past its ceiling: nothing is saved.
    func refuseWrites(_ refuse: Bool) { lock.lock(); refusing = refuse; lock.unlock() }

    func read() -> VenueTokenList.Stored {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return stored
    }

    func write(_ list: Data, _ checkpoint: UInt64, _ dropped: Data) -> Bool {
        let symbols = ((try? JSONDecoder().decode([Token].self, from: list)) ?? []).map(\.symbol)
        lock.lock(); defer { lock.unlock() }
        attempted.append(checkpoint)
        guard !refusing else { return false }
        stored = VenueTokenList.Stored(list: list, checkpoint: checkpoint, dropped: dropped)
        written.append((symbols, checkpoint))
        return true
    }

    /// A list on the stubs (`LogsStub`, named like rpc1, and `MomentsChainStub`) kept in this store.
    @MainActor
    func list(now: @escaping @Sendable () -> Date = { Date() }) -> VenueTokenList {
        VenueTokenList(service: VenueTokensService(logsRPC: LogsStub.rpc(), multicall: Multicall(rpc: MomentsChainStub.rpc())), logos: { [:] },
                       read: { self.read() }, write: { self.write($0, $1, $2) }, now: now)
    }
}

/// A clock a test moves by hand, from `start`; `read` is it as the `now` closure the code under test takes.
final class TestClock: @unchecked Sendable {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let lock = NSLock()
    private var date: Date
    init() { date = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    var read: @Sendable () -> Date { { [self] in now } }
    func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
}

/// A switch a stub's rule reads while a test flips it.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var on: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
}
