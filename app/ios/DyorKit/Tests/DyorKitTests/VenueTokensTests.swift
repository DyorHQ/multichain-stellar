import BigInt
import XCTest
@testable import DyorKit

/// The swap picker's venue list (`VenueTokensService`): every token that gained a pool on Uniswap v3, Monday Trade or
/// Uniswap v4, read from genesis in segments. Build 16 read it on rpc3 in ranges rpc3 refuses, and moved its checkpoint
/// past every segment, gaps and all, so tokens a gap hid never reached the list.
final class VenueTokensTests: XCTestCase {
    private let created = ABI.eventTopic("PoolCreated(address,address,uint24,int24,address)")
    private let initialized = ABI.eventTopic("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)")

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    private func token(_ n: UInt8) -> Address { Address(data: Data(repeating: 0, count: 19) + Data([n]))! }

    /// A pool for token `n` against WMON at `block`: on Uniswap v3, Monday Trade or Uniswap v4 by `n % 3`.
    private func pool(_ n: UInt8, at block: UInt64) -> Log {
        let word = { (address: Address) in address.data.leftPadded(to: 32) }
        let hash = Data(repeating: n, count: 32)
        switch n % 3 {
        case 0: return Log(address: Uniswap.v3Factory, topics: [created, word(token(n)), word(Monad.wmon), BigUInt(3000).word], data: Data(count: 64),
                           blockNumber: block, transactionHash: hash, logIndex: 0)
        case 1: return Log(address: MondayTrade.factory, topics: [created, word(Monad.wmon), word(token(n)), BigUInt(3000).word], data: Data(count: 64),
                           blockNumber: block, transactionHash: hash, logIndex: 0)
        default: return Log(address: Uniswap.poolManager, topics: [initialized, hash, word(Monad.native), word(token(n))], data: Data(count: 160),
                            blockNumber: block, transactionHash: hash, logIndex: 0)
        }
    }

    /// Every token answers its symbol ("T" and its number), name and 18 decimals; `breaking` tokens take down any
    /// metadata read that reaches them, and `starving` ones starve every call after theirs in the read (`MomentsChainStub`).
    private func installMetadata(breaking: Set<Address> = [], starving: Set<Address> = []) {
        MomentsChainStub.install({ to, data in
            let selector = data.prefix(4)
            if selector == ABI.selector("symbol()") || selector == ABI.selector("name()") { return try! ABI.encode([.string("T\(to.data.last ?? 0)")], "string") }
            if selector == ABI.selector("decimals()") { return try! ABI.encode([.uint(18)], "uint8") }
            return nil
        }, breaking: breaking, starving: starving)
    }

    /// The service on the stubs: named like rpc1 unless `url` says otherwise.
    private func service(_ url: URL = LogsStub.url) -> VenueTokensService {
        VenueTokensService(logsRPC: LogsStub.rpc(url: url), multicall: Multicall(rpc: MomentsChainStub.rpc()))
    }

    /// Every save a refresh made, in order.
    private actor Saves {
        private(set) var all: [(symbols: [String], checkpoint: UInt64, complete: Bool)] = []
        func record(_ progress: VenueTokensService.Progress) { all.append((progress.tokens.map(\.symbol), progress.checkpoint, progress.complete)) }
    }

    /// A segment read in part keeps what it found, but not its checkpoint: the refresh ends there, and the next one reads
    /// the segment again and finds what the gap hid, then reads on to the head.
    func testASegmentReadInPartKeepsItsCheckpointAndIsReadAgain() async throws {
        installMetadata()
        // T6 and T3 on Uniswap v3, T1 and T4 on Monday Trade.
        let pools = [pool(1, at: 1_000_000), pool(6, at: 6_000_000), pool(3, at: 7_000_000), pool(4, at: 11_000_000)]
        // An endpoint that refuses, at every size, any range holding block 7,000,000: a gap in the second segment.
        LogsStub.install(head: 12_000_000, logs: pools) { range in
            range.contains(7_000_000) ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let saves = Saves()
        let firstRead = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }) { await saves.record($0) }
        let first = try XCTUnwrap(firstRead)
        let firstSaves = await saves.all
        XCTAssertEqual(firstSaves.map(\.checkpoint), [4_999_999, 4_999_999], "the first segment in full; the second in part, which moves nothing")
        XCTAssertEqual(firstSaves.map(\.complete), [false, false])
        XCTAssertEqual(firstSaves.last?.symbols, ["T1", "T6"], "what the second segment found is kept")
        XCTAssertEqual(first.checkpoint, 4_999_999)
        XCTAssertEqual(first.head, 12_000_000)
        XCTAssertFalse(first.complete)
        XCTAssertFalse(LogsStub.queries().contains { $0.to >= 10_000_000 }, "the refresh ends at the segment read in part")
        let second5M = zip(LogsStub.queries(), LogsStub.addresses()).filter { $0.0.from >= 5_000_000 }.map(\.1)
        XCTAssertEqual(Set(second5M), [Uniswap.v3Factory], "a venue read in part ends the segment's read: the others aren't asked")

        LogsStub.install(head: 12_000_000, logs: pools) { _ in nil }
        let secondRead = await service().refresh(tokens: first.tokens, checkpoint: first.checkpoint, logos: { [:] }) { await saves.record($0) }
        let second = try XCTUnwrap(secondRead)
        XCTAssertEqual(second.tokens.map(\.symbol), ["T1", "T6", "T3", "T4"], "the gap's token found, none twice")
        XCTAssertEqual(second.checkpoint, 11_999_900, "100 blocks behind the head (`headMargin`)")
        XCTAssertTrue(second.complete)
        XCTAssertEqual(LogsStub.queries().map(\.from).min(), 5_000_000, "read again from the segment read in part")
        let secondSaves = await saves.all.dropFirst(firstSaves.count)
        XCTAssertEqual(secondSaves.map(\.checkpoint), [9_999_999, 11_999_900])
        XCTAssertEqual(secondSaves.map(\.complete), [false, true])
    }

    /// On an endpoint that answers 1,000 blocks a request, as rpc3 does, every venue is read in full and says so (a
    /// 5M-block segment: `LogScanTests.testAnEndpointThatAnswers1000BlocksReadsA5MBlockSegmentWithNoGap`).
    func testAnEndpointThatAnswers1000BlocksReadsEveryVenueInFull() async {
        installMetadata()
        let pools = [pool(3, at: 100_000_500), pool(4, at: 100_070_000), pool(5, at: 100_130_001), pool(6, at: 100_199_999)]
        LogsStub.install(head: 105_000_000, logs: pools, batchSpan: 1_000) { range in
            range.span > 1_000 ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let scan = await service(LogsStub.rpc3).tokens(fromBlock: 100_000_000, toBlock: 100_199_999)
        XCTAssertTrue(scan.complete)
        XCTAssertFalse(scan.capped)
        XCTAssertEqual(Set(scan.tokens.map(\.symbol)), ["T3", "T4", "T5", "T6"])
        XCTAssertEqual(LogsStub.queries().count, 600, "three venues, 200 ranges each, none refused")
    }

    /// The finding: the refill read rpc1 in 100,000-block ranges, the three venues at once: 2,714 requests on the endpoint
    /// every other reader in the app shares, 1,000 of them answered HTTP 429. On rpc1, which answers a range of any span
    /// up to its log cap, each venue's segment is one range, the venues one after the other, one request at a time: 22
    /// segments from genesis take 66 ranges, one more where a venue holds more logs than rpc1 returns and it names the
    /// part it can (as an HTTP 400, as rpc1 sends it for one call), and the head.
    func testARefillFromGenesisTakesAboutSeventyRequestsOneAtATime() async throws {
        installMetadata()
        let head: UInt64 = 109_175_022
        // One pool a venue a segment; in the eighth, four more on v4, past this rpc1's cap of three logs an answer.
        var pools: [Log] = (1...66).map { n in pool(UInt8(n), at: UInt64((n - 1) / 3) * VenueTokensService.segment + 1_000 + UInt64(n)) }
        pools += [200, 203, 206, 209].map { pool($0, at: 7 * VenueTokensService.segment + 2_000_000 + UInt64($0)) }
        LogsStub.install(head: head, logs: pools, singleErrorStatus: 400, latency: 0.002, logCap: 3) { _ in nil }
        let refreshed = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }) { _ in }
        let read = try XCTUnwrap(refreshed)
        XCTAssertTrue(read.complete)
        XCTAssertEqual(read.tokens.count, 70)
        XCTAssertEqual(LogsStub.requests(), 69, "the head, 66 ranges, and one more for the part rpc1 named")
        XCTAssertEqual(LogsStub.queries().count, 68, "one range a request")
        XCTAssertEqual(LogsStub.maxInFlight(), 1, "one request at a time")
        var order: [Address?] = []
        for address in LogsStub.addresses() where address != order.last { order.append(address) }
        let venues: [Address?] = [Uniswap.v3Factory, MondayTrade.factory, Uniswap.poolManager]
        XCTAssertEqual(order, Array((0..<22).map { _ in venues }.joined()), "each segment: v3, then Monday Trade, then v4")
    }

    /// More tokens than a read keeps: the newest are kept and the read says so; a read of the same window that excludes
    /// them brings the rest, and a refresh makes that read at once, moving the checkpoint only once every one is in.
    func testMoreTokensThanAReadKeepsAreReadAgainAtOnce() async throws {
        installMetadata()
        LogsStub.install(head: 1_000, logs: [pool(1, at: 10), pool(3, at: 20), pool(4, at: 30)]) { _ in nil }
        let first = await service().tokens(fromBlock: 0, toBlock: 1_000, limit: 2)
        XCTAssertTrue(first.complete)
        XCTAssertTrue(first.capped)
        XCTAssertEqual(first.tokens.map(\.symbol), ["T4", "T3"], "the newest first")
        let second = await service().tokens(fromBlock: 0, toBlock: 1_000, exclude: Set(first.tokens.map(\.address)), limit: 2)
        XCTAssertTrue(second.complete)
        XCTAssertFalse(second.capped)
        XCTAssertEqual(second.tokens.map(\.symbol), ["T1"])

        let saves = Saves()
        let refreshed = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }, limit: 2) { await saves.record($0) }
        let read = try XCTUnwrap(refreshed)
        XCTAssertEqual(read.tokens.map(\.symbol), ["T4", "T3", "T1"])
        XCTAssertEqual(read.checkpoint, 900)
        let saved = await saves.all
        XCTAssertEqual(saved.map(\.symbols), [["T4", "T3"], ["T4", "T3", "T1"]])
        XCTAssertEqual(saved.map(\.checkpoint), [0, 900], "the checkpoint waits for the second read")
    }

    /// A segment whose newest tokens have no readable symbol still reads the rest: the re-read leaves out what the read
    /// dropped, as it leaves out what it kept, so a segment full of such tokens can't hold the checkpoint for good.
    func testTokensWithNoSymbolDontHoldASegmentThatIsReadAgain() async throws {
        let (newest, next) = (token(4), token(3))
        MomentsChainStub.install { to, data in
            guard to != newest, to != next, data.prefix(4) == ABI.selector("symbol()") else { return nil }
            return try! ABI.encode([.string("T\(to.data.last ?? 0)")], "string")
        }
        LogsStub.install(head: 1_000, logs: [pool(1, at: 10), pool(3, at: 20), pool(4, at: 30)]) { _ in nil }
        let first = await service().tokens(fromBlock: 0, toBlock: 1_000, limit: 2)
        XCTAssertTrue(first.complete)
        XCTAssertTrue(first.capped)
        XCTAssertTrue(first.tokens.isEmpty)
        XCTAssertEqual(first.dropped, [newest, next])
        let saves = Saves()
        let refreshed = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }, limit: 2) { await saves.record($0) }
        let read = try XCTUnwrap(refreshed)
        XCTAssertEqual(read.tokens.map(\.symbol), ["T1"])
        XCTAssertEqual(read.checkpoint, 900)
        let checkpoints = await saves.all.map(\.checkpoint)
        XCTAssertEqual(checkpoints, [0, 900], "the checkpoint waits for the read that leaves the dropped out")
    }

    /// The finding: a token that takes its read down (a return bomb, or a symbol that burns the gas) made the other 49
    /// tokens of its read unread, so the segment was never read in full and the checkpoint never moved again. Its read is
    /// now read again token by token: the others are found, the token at fault alone is dropped, and the segment is read
    /// in full.
    func testATokenThatBreaksItsReadCostsOnlyItself() async throws {
        installMetadata(breaking: [token(2)])
        LogsStub.install(head: 1_000, logs: [pool(1, at: 10), pool(2, at: 20), pool(3, at: 30)]) { _ in nil }
        let scan = await service().tokens(fromBlock: 0, toBlock: 1_000)
        XCTAssertTrue(scan.complete)
        XCTAssertEqual(scan.tokens.map(\.symbol), ["T3", "T1"])
        XCTAssertEqual(scan.dropped, [token(2)])
        let refreshed = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }) { _ in }
        let read = try XCTUnwrap(refreshed)
        XCTAssertEqual(read.checkpoint, 900, "the checkpoint moves on")
        XCTAssertEqual(read.tokens.map(\.symbol), ["T3", "T1"])
    }

    /// The finding: a token starved of gas by a token before it in the same read (Multicall3 reports it as a failed call,
    /// as it does a token with no symbol) was dropped, and the checkpoint moved past its pool for good. A token whose
    /// symbol can't be read in its read is read again on its own: only one that still can't be read is dropped.
    func testATokenStarvedOfGasInItsReadIsFoundOnItsOwn() async throws {
        let (burner, victim) = (token(9), token(8))
        installMetadata(starving: [burner])
        // The burner's v3 pool is read first (Uniswap v3 and Monday Trade, newest first, then v4), so T1 on Monday Trade
        // and the victim on v4 come after it in the read.
        LogsStub.install(head: 1_000, logs: [pool(1, at: 10), pool(8, at: 20), pool(9, at: 30)]) { _ in nil }
        let scan = await service().tokens(fromBlock: 0, toBlock: 1_000)
        XCTAssertTrue(scan.complete)
        XCTAssertEqual(scan.tokens.map(\.symbol), ["T1", "T8"])
        XCTAssertEqual(scan.dropped, [burner], "the burner, read on its own, still has no symbol")
        let direct = await ERC20.metadataReport([burner, victim, token(1)], multicall: Multicall(rpc: MomentsChainStub.rpc()))
        XCTAssertEqual(direct.tokens.map(\.address), [victim, token(1)])
        XCTAssertTrue(direct.unread.isEmpty)
    }

    /// Addresses as anyone can put in Uniswap v4 pools (`initialize` takes any pair).
    private func addresses(_ count: Int) -> [Address] {
        (1...count).map { Address(data: Data(repeating: 0, count: 16) + Data([0x7e, 0x57, UInt8(($0 >> 8) & 0xff), UInt8($0 & 0xff)]))! }
    }

    /// `addresses`' metadata, read with the app's budget.
    private func metadataReport(_ addresses: [Address]) async -> ERC20.MetadataReport {
        await ERC20.metadataReport(addresses, multicall: Multicall(rpc: MomentsChainStub.rpc()), rereads: VenueTokensService.metadataRereads)
    }

    /// The finding: every address whose symbol couldn't be read in its read was read again on its own, one request each on
    /// the endpoint Send, Swap and prices use: 3,000 addresses cost 3,060 requests where they had cost 60 (250 here: 255
    /// where they had cost 5). An account with no code answers `symbol()` with nothing, a call that returned, so it wasn't
    /// starved of gas: it isn't read on its own. The V1 final check's finding: such an address was dropped after that one
    /// read, so a real token read from a node behind the chain (which answers a token it hasn't reached as an account with
    /// no code) was lost for good. It is read once more, with the rest of its read, then dropped: one more request a read
    /// at most.
    func testAnAddressThatAnswersWhatIsntASymbolIsReadOnceMoreWithTheRestOfItsRead() async {
        let all = addresses(250)
        MomentsChainStub.install { _, _ in Data() }
        let report = await metadataReport(all)
        XCTAssertEqual(MomentsChainStub.batches().count, 10, "one request a 50, and one more for the 50 together")
        XCTAssertEqual(report.dropped, all)
        XCTAssertTrue(report.tokens.isEmpty)
        XCTAssertTrue(report.unread.isEmpty)
        XCTAssertEqual(report.rereads, 5)

        // A real token that answers nothing the first time, its symbol the next, beside a token whose symbol reverts: found
        // when the rest of its read is read again.
        let (lagging, reverting) = (all[7], all[20])
        let asked = Counter()
        MomentsChainStub.install { to, data in
            if to == reverting { return nil }
            if to == lagging, data.prefix(4) == ABI.selector("symbol()"), asked.next() == 1 { return Data() }
            return Self.symbolAnswer(to, data)
        }
        let found = await metadataReport(Array(all.prefix(50)))
        XCTAssertEqual(found.tokens.count, 49)
        XCTAssertTrue(found.tokens.contains { $0.address == lagging }, "found in the read again")
        XCTAssertEqual(found.dropped, [reverting])
        XCTAssertTrue(found.unread.isEmpty)
        XCTAssertEqual(MomentsChainStub.batches().count, 3, "the read, the reverting token on its own, and the rest again")

        // The V1 last check's finding (I1): it went after the others in that second read, so a token there that burns gas
        // starved it and it was read once more on its own. It goes first: never starved, never asked alone.
        let odd = all[0]
        let burners: Set<Address> = [all[10], all[20]]
        MomentsChainStub.install({ to, data in to == odd ? Data() : Self.symbolAnswer(to, data) }, starving: burners)
        let beside = await metadataReport(Array(all.prefix(50)))
        XCTAssertEqual(Set(beside.dropped), burners.union([odd]), "it, and the two that burn gas even on their own")
        XCTAssertEqual(beside.tokens.count, 47, "every other token found")
        XCTAssertFalse(MomentsChainStub.batches().contains { Set($0.map(\.to)) == [odd] }, "never read on its own")
    }

    /// A token that burns the gas of its read starves every token after it: the first that failed is read on its own,
    /// the others once more together, where each was read on its own (51 requests a read).
    func testATokenThatStarvesItsReadCostsTwoMoreRequests() async {
        let all = addresses(250)
        let burners = stride(from: 0, to: 250, by: 50).map { all[$0] }
        installMetadata(starving: Set(burners))
        let report = await metadataReport(all)
        XCTAssertEqual(MomentsChainStub.batches().count, 15, "each read, its burner on its own, and the other 49 together")
        XCTAssertEqual(report.tokens.count, 245)
        XCTAssertEqual(report.dropped, burners)
        XCTAssertTrue(report.unread.isEmpty)
        XCTAssertEqual(report.rereads, 10)
    }

    /// Symbols that revert can't be told from starved ones, so they are read again, and one by one only what fails again;
    /// a real token that reverts costs one request. At most `metadataRereads` requests go past the first reads: the rest
    /// is unread, for a later run (3,000 such addresses: 260 requests, where they cost 3,060).
    func testRevertingSymbolsAreReadAgainWithinTheBudget() async {
        let all = addresses(250)
        MomentsChainStub.install { _, _ in nil }
        let report = await metadataReport(all)
        XCTAssertEqual(MomentsChainStub.batches().count, 5 + VenueTokensService.metadataRereads)
        XCTAssertEqual(report.rereads, 200)
        // Three reads in full (1 + 1 + 49 each), then the fourth's first alone, the other 49 together, and 45 of them.
        XCTAssertEqual(report.dropped, Array(all.prefix(196)))
        XCTAssertEqual(report.unread, Array(all.dropFirst(196)))
        XCTAssertTrue(report.tokens.isEmpty)

        let one = all[9]
        MomentsChainStub.install { to, data in to == one ? nil : Self.symbolAnswer(to, data) }
        let honest = await metadataReport(Array(all.prefix(100)))
        XCTAssertEqual(MomentsChainStub.batches().count, 3, "two reads, and the token that reverts on its own")
        XCTAssertEqual(honest.tokens.count, 99)
        XCTAssertEqual(honest.dropped, [one])
    }

    /// Reads that fail as a whole (a return bomb in each) are read again the same way, within the same budget.
    func testReadsThatBreakAsAWholeAreReadAgainWithinTheBudget() async {
        let all = addresses(250)
        MomentsChainStub.install({ _, _ in nil }, breaking: Set(all))
        let report = await metadataReport(all)
        XCTAssertEqual(MomentsChainStub.batches().count, 205)
        XCTAssertEqual(report.dropped, Array(all.prefix(196)))
        XCTAssertEqual(report.unread, Array(all.dropFirst(196)), "unread, not dropped: a later run reads them")
        XCTAssertEqual(report.rereads, 200)
    }

    /// A refresh spends one budget on all its segments, and a run handed what an earlier one dropped doesn't read it again:
    /// a segment left short by the budget is read in full over a few runs, never paying twice for an address.
    func testARefreshReadsWithinItsBudgetAndLeavesOutWhatWasDropped() async throws {
        let bad = Set((1...12).map { token(UInt8($0)) })
        MomentsChainStub.install { to, data in bad.contains(to) ? nil : Self.symbolAnswer(to, data) }
        LogsStub.install(head: 1_000, logs: (1...13).map { pool(UInt8($0), at: UInt64($0) * 10) }) { _ in nil }
        var dropped: Set<Address> = []
        var runs: [(calls: Int, complete: Bool)] = []
        for _ in 0..<3 {
            MomentsChainStub.install { to, data in bad.contains(to) ? nil : Self.symbolAnswer(to, data) }
            let refreshed = await service().refresh(tokens: [], checkpoint: 0, dropped: dropped, logos: { [:] }, rereads: 5) { _ in }
            let read = try XCTUnwrap(refreshed)
            XCTAssertTrue(MomentsChainStub.calls().allSatisfy { !dropped.contains($0.to) }, "what a run before dropped isn't read")
            XCTAssertTrue(read.dropped.isSuperset(of: dropped))
            dropped = read.dropped
            runs.append((MomentsChainStub.batches().count, read.complete))
            if read.complete {
                XCTAssertEqual(read.tokens.map(\.symbol), ["T13"])
                XCTAssertEqual(read.checkpoint, 900)
            }
        }
        XCTAssertEqual(runs.map(\.calls), [6, 6, 6], "a read, then five more at most, each run")
        XCTAssertEqual(runs.map(\.complete), [false, false, true])
        XCTAssertEqual(dropped, bad)
    }

    /// A token's symbol and name ("T" and its last byte) and 18 decimals.
    private static func symbolAnswer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        if selector == ABI.selector("symbol()") || selector == ABI.selector("name()") { return try! ABI.encode([.string("T\(to.data.last ?? 0)")], "string") }
        if selector == ABI.selector("decimals()") { return try! ABI.encode([.uint(18)], "uint8") }
        return nil
    }

    /// A token whose metadata read got no answer isn't dropped for good: the read is incomplete, so the checkpoint stays
    /// and the segment is read again next time. One with no readable symbol is dropped, as it always was.
    func testAMetadataReadWithNoAnswerLeavesTheSegmentToBeReadAgain() async throws {
        // The node answers no `eth_call` ("header not found"): nothing is known of either token.
        MomentsChainStub.install({ _, _ in nil }, refusing: ["eth_call"])
        LogsStub.install(head: 1_000, logs: [pool(1, at: 10), pool(2, at: 20)]) { _ in nil }
        let scan = await service().tokens(fromBlock: 0, toBlock: 1_000)
        XCTAssertFalse(scan.complete, "no answer")
        XCTAssertTrue(scan.tokens.isEmpty)
        XCTAssertTrue(scan.dropped.isEmpty, "unread, not dropped")
        let saves = Saves()
        let refreshed = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }) { await saves.record($0) }
        let read = try XCTUnwrap(refreshed)
        XCTAssertEqual(read.checkpoint, 0)
        XCTAssertFalse(read.complete)
        let checkpoints = await saves.all.map(\.checkpoint)
        XCTAssertEqual(checkpoints, [0])

        let unreadable = token(2)
        MomentsChainStub.install { to, data in
            guard to != unreadable, data.prefix(4) == ABI.selector("symbol()") else { return nil }
            return try! ABI.encode([.string("T1")], "string")
        }
        let readable = await service().tokens(fromBlock: 0, toBlock: 1_000)
        XCTAssertTrue(readable.complete, "a token with no symbol is dropped, not unread")
        XCTAssertEqual(readable.tokens.map(\.symbol), ["T1"])
    }

    /// The checkpoint stays `headMargin` (100 blocks) behind the head: the head comes from one rpc1 node and the logs from
    /// another, which refuses a range past its own head ("block range extends beyond current head block", probed live),
    /// and the newest blocks may not be final. A node a few blocks behind no longer leaves the newest segment a gap, and
    /// a pool in the last 100 blocks is read by the next run.
    func testTheCheckpointStaysBehindTheHead() async throws {
        installMetadata()
        let head: UInt64 = 10_000_000
        let pools = [pool(1, at: 1_000_000), pool(3, at: head - 150), pool(4, at: head - 50)]
        // The node answering the logs is three blocks behind the one that answered the head.
        let lagging = { (head: UInt64) -> LogsStub.Rule in
            { range in range.to > head - 3 ? .error(code: -32602, message: "block range extends beyond current head block") : nil }
        }
        LogsStub.install(head: head, logs: pools, rule: lagging(head))
        let firstRead = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }) { _ in }
        let first = try XCTUnwrap(firstRead)
        XCTAssertTrue(first.complete)
        XCTAssertEqual(first.checkpoint, head - 100)
        XCTAssertEqual(first.tokens.map(\.symbol), ["T1", "T3"], "T4, 50 blocks from the head, waits for the next run")
        XCTAssertTrue(LogsStub.queries().allSatisfy { $0.to <= head - 100 })

        LogsStub.install(head: head + 200, logs: pools, rule: lagging(head + 200))
        let nextRead = await service().refresh(tokens: first.tokens, checkpoint: first.checkpoint, logos: { [:] }) { _ in }
        let next = try XCTUnwrap(nextRead)
        XCTAssertEqual(next.tokens.map(\.symbol), ["T1", "T3", "T4"])
        XCTAssertEqual(LogsStub.queries().map(\.from).min(), head - 99)
    }

    /// A token's `symbol()` and `name()` can return a string of any length; the list keeps 32 and 64 characters of them.
    func testALongSymbolOrNameIsCapped() async {
        let long = token(5)
        MomentsChainStub.install { to, data in
            let selector = data.prefix(4)
            let text = to == long ? String(repeating: "W", count: 1_000) : "T\(to.data.last ?? 0)"
            if selector == ABI.selector("symbol()") || selector == ABI.selector("name()") { return try! ABI.encode([.string(text)], "string") }
            return nil
        }
        LogsStub.install(head: 1_000, logs: [pool(1, at: 10), pool(5, at: 20)]) { _ in nil }
        let scan = await service().tokens(fromBlock: 0, toBlock: 1_000)
        XCTAssertTrue(scan.complete)
        let capped = scan.tokens.first { $0.address == long }
        XCTAssertEqual(capped?.symbol, String(repeating: "W", count: 32))
        XCTAssertEqual(capped?.name, String(repeating: "W", count: 64))
        XCTAssertEqual(scan.tokens.first { $0.address == token(1) }?.symbol, "T1", "a short one as it is")
    }

    /// The re-review's finding: the caps counted characters, and "A" with 50,000 combining accents is one character, 100 KB
    /// in a list stored whole. They count Unicode scalars: 32 and 64 of them, 128 and 256 bytes at most.
    func testASymbolOfCombiningMarksIsCappedByScalars() async {
        let heavy = "A" + String(repeating: "\u{0301}", count: 50_000)
        XCTAssertEqual(heavy.count, 1)
        let capped = VenueTokensService.capped(Token(address: token(1), symbol: heavy, name: heavy, decimals: 18))
        XCTAssertEqual(capped.symbol.unicodeScalars.count, 32)
        XCTAssertEqual(capped.name.unicodeScalars.count, 64)
        XCTAssertLessThanOrEqual(capped.symbol.utf8.count, 128)
        XCTAssertLessThanOrEqual(capped.name.utf8.count, 256)
        XCTAssertEqual(capped.symbol.unicodeScalars.first, "A")

        let long = token(5)
        MomentsChainStub.install { to, data in
            let selector = data.prefix(4)
            let text = to == long ? heavy : "T\(to.data.last ?? 0)"
            if selector == ABI.selector("symbol()") || selector == ABI.selector("name()") { return try! ABI.encode([.string(text)], "string") }
            return nil
        }
        LogsStub.install(head: 1_000, logs: [pool(1, at: 10), pool(5, at: 20)]) { _ in nil }
        let scan = await service().tokens(fromBlock: 0, toBlock: 1_000)
        XCTAssertLessThanOrEqual(scan.tokens.first { $0.address == long }?.symbol.utf8.count ?? .max, 128, "a new read")
        let stored = VenueTokenList.decode(.init(list: try? JSONEncoder().encode([Token(address: long, symbol: heavy, name: heavy, decimals: 18)]), checkpoint: 7))
        XCTAssertEqual(stored.tokens.map(\.symbol.unicodeScalars.count), [32], "a list read from the store")
    }

    /// A head that couldn't be read reads nothing and says so; a list already at the head reads nothing and is complete.
    func testNothingIsReadWithoutAHead() async throws {
        installMetadata()
        LogsStub.install(head: 0) { _ in nil }
        let none = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }) { _ in XCTFail("nothing to save") }
        XCTAssertNil(none)
        LogsStub.install(head: 500) { _ in nil }
        let atHeadRead = await service().refresh(tokens: [], checkpoint: 500, logos: { [:] }) { _ in XCTFail("nothing to save") }
        let atHead = try XCTUnwrap(atHeadRead)
        XCTAssertTrue(atHead.complete)
        XCTAssertTrue(LogsStub.queries().isEmpty)
    }

    /// The app reads the venues on rpc1, one request at a time, and reads the whole history once more: the list
    /// is kept, and the checkpoint is a new one, since build 16's moved past gaps, under a key that can't mark the install
    /// as earlier than App Lock's default (`AppSettings`, security audit 2026-09-26, IOSK-4). The list is kept in memory
    /// (`VenueTokenList`): the swap picker searches it there, never the store, and says while it is short.
    func testTheAppReadsTheVenuesOnRpc1AndReadsTheirHistoryOnceMore() throws {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        let app = ios.appendingPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        // Read with every run of whitespace as one space (`squeezed`): the checks pin the code, not its indentation.
        let environment = squeezed(try String(contentsOf: app.appendingPathComponent("App/AppEnvironment.swift"), encoding: .utf8))
        // The venue scan goes through the app's one logs client: the router over every public endpoint, behind the gate
        // the wallet's history shares (`LogsRouter`), so the two never throttle each other.
        XCTAssertTrue(environment.contains("venueTokens = VenueTokensService(logsRPC: logsClient, multicall: multicall)"))
        XCTAssertTrue(environment.contains("logsClient = isFork ? RPCClient(url: config.rpcURL) : RPCClient(logsRouter: logsRouter)"))
        XCTAssertFalse(environment.contains("rpc3.monad.xyz"), "no endpoint named here: the router's list (`LogsEndpoints.monadMainnet`) is the one place")
        XCTAssertTrue(environment.contains("venueList = VenueTokenList(service: venueTokens, logos: { [kuruTokens] in await kuruTokens.logos() },"))
        XCTAssertTrue(environment.contains("read: { VenueTokenStore.read() }, write: { VenueTokenStore.write($0, lastBlock: $1, dropped: $2) })"))
        XCTAssertEqual(environment.components(separatedBy: "VenueTokenStore.").count - 1, 2, "the list reads and writes the store; nothing else does")
        // A cold launch runs the list; every return to the app resets log scans' outage and resumes a run that ended short.
        let root = squeezed(try String(contentsOf: app.appendingPathComponent("App/RootView.swift"), encoding: .utf8))
        // ...the stored list read at once for search, and the run told, on every change, which wallet is signed in and
        // whether its history is filling in — as it is too while the history model isn't on that wallet yet
        // (`VenueTokenList.follow`): paused while a wallet's history fills in for the first time (the two share the gate),
        // and, with no wallet signed in, held while nothing was read. In build 22 and earlier the run started at once with
        // no wallet signed in — a fresh install's read from genesis during onboarding — and nothing paused it once the
        // history started filling. Nothing while the session is restored at launch.
        XCTAssertTrue(root.contains(".task { await env.venueList.load() }"))
        XCTAssertTrue(root.contains(".task(id: \"\\(session.state == .loading)-\\(session.address?.hex ?? \"\")-\\(env.history.wallet?.hex ?? \"\")-\\(env.history.filling)\") { "
                                    + "guard session.state != .loading else { return } "
                                    + "env.followVenueTokens(wallet: session.address, historyFilling: env.history.wallet != session.address || env.history.filling) }"))
        XCTAssertTrue(environment.contains("func followVenueTokens(wallet: Address?, historyFilling: Bool) { venueList.follow(wallet: wallet, historyFilling: historyFilling) }"))
        // Nothing else starts a run: a return to the app resumes one that ended short (below), which waits as a run does.
        var starts = 0
        for file in FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }) ?? [] where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            starts += source.components(separatedBy: "venueList.refresh()").count - 1 + source.components(separatedBy: "refreshVenueTokens").count - 1
        }
        XCTAssertEqual(starts, 0, "the app starts the list's run through `follow` only")
        // In the scene-phase handler, wherever its branches sit: the background is noted, and only the activation that
        // follows it, a return, resets log scans' outage and resumes the list (`LogScanClock`).
        let phases = try XCTUnwrap(root.range(of: ".onChange(of: scenePhase)")).upperBound
        let background = try XCTUnwrap(root[phases...].range(of: "if phase == .background {")).upperBound
        XCTAssertTrue(root[background...].prefix { $0 != "}" }.contains("LogScanClock.suspended()"))
        XCTAssertTrue(root[phases...].contains("if LogScanClock.resumed() { env.venueList.resume() }"))
        XCTAssertEqual(root.components(separatedBy: "LogScanClock.resumed()").count - 1, 1, "nothing else resets the outage")
        XCTAssertEqual(LaunchpadService.defaultLogsRPC.absoluteString, "https://rpc1.monad.xyz")
        let service = squeezed(try String(contentsOf: ios.appendingPathComponent("DyorKit/Sources/DyorKit/Services/VenueTokensService.swift"), encoding: .utf8))
        XCTAssertTrue(service.contains("public init(logsRPC: RPCClient, multicall: Multicall) {"))
        XCTAssertTrue(service.contains("concurrency: 1, mode: .paced, lane: .background)"),
                      "one request at a time, a throttle waited out, in the gate's background lane: behind every screen's scan and the wallet's history")

        let store = try String(contentsOf: app.appendingPathComponent("Wallet/VenueTokenStore.swift"), encoding: .utf8)
        XCTAssertTrue(store.contains("private static let key = \"venueTokens.v1\""), "the list is kept")
        XCTAssertTrue(store.contains("private static let blockKey = \"venueScan.v2.lastBlock\""), "a new checkpoint: the history read once more")
        XCTAssertTrue(store.contains("private static let droppedKey = \"venueScan.v2.dropped\""), "what runs dropped, kept across launches")
        XCTAssertFalse(store.contains("\"venueTokens.v1.lastBlock\""), "build 16's checkpoint is never read, nor written")
        // The checkpoint is saved only once the list reads back as written (UserDefaults refuses a value past its ceiling).
        let write = squeezed(store)
        // It says whether it saved them, and the list counts a save only then (`VenueTokenList.store`).
        let readBack = try XCTUnwrap(write.range(of: "UserDefaults.standard.set(list, forKey: key) guard UserDefaults.standard.data(forKey: key) == list else { return false }"))
        let checkpoint = try XCTUnwrap(write.range(of: "UserDefaults.standard.set(String(lastBlock), forKey: blockKey)"))
        XCTAssertLessThan(readBack.upperBound, checkpoint.lowerBound)
        XCTAssertTrue(write.contains("static func write(_ list: Data, lastBlock: UInt64, dropped: Data) -> Bool {"))
        // What runs dropped is saved with the checkpoint, after the read-back, and read with it.
        let droppedSave = try XCTUnwrap(write.range(of: "UserDefaults.standard.set(dropped, forKey: droppedKey) return true }"))
        XCTAssertLessThan(checkpoint.upperBound, droppedSave.lowerBound)
        XCTAssertTrue(write.contains("dropped: UserDefaults.standard.data(forKey: droppedKey))"))
        // R4: every key the store names, beyond build 16's list and stamp, is outside the prefixes that mark an earlier
        // install.
        let theme = try String(contentsOf: app.appendingPathComponent("Design/Theme.swift"), encoding: .utf8)
        let earlierRun = try XCTUnwrap(theme.range(of: "let earlierRun = [")).upperBound
        let quotesAndSpace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))
        let prefixes = theme[earlierRun...].prefix { $0 != "]" }.split(separator: ",").map { $0.trimmingCharacters(in: quotesAndSpace) }
        XCTAssertTrue(prefixes.contains("venueTokens."), "\(prefixes)")
        let keys = store.components(separatedBy: "\n").filter { $0.contains("Key = \"") || $0.contains("key = \"") }
            .compactMap { line in line.split(separator: "\"").dropFirst().first.map(String.init) }
        XCTAssertEqual(keys, ["venueTokens.v1", "venueTokens.v1.updatedAt", "venueScan.v2.lastBlock", "venueScan.v2.dropped"])
        for key in keys.dropFirst(2) { XCTAssertFalse(prefixes.contains { key.hasPrefix($0) }, "\(key) would mark a fresh install as earlier (R4)") }

        // R4: every erase of this device's data stops the list's reading first, so no save of it follows the erase.
        var erases = 0
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains(".eraseLocalData()") && !line.contains("func eraseLocalData") {
                erases += 1
                // Anywhere before the erase in the function that makes it, whatever else runs between them.
                let function = lines[..<i].lastIndex { $0.contains("func ") } ?? 0
                XCTAssertTrue(lines[function..<i].contains { $0.contains("env.venueList.stop()") }, "\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertEqual(erases, 2, "Delete Account, and this device's erase (a passkey account's deletion, Forget This Device)")

        let swap = squeezed(try String(contentsOf: app.appendingPathComponent("Swap/SwapView.swift"), encoding: .utf8))
        XCTAssertFalse(swap.contains("VenueTokenStore"), "the search never reads the store")
        XCTAssertTrue(swap.contains("let venueHits = env.venueList.tokens.filter {"))
        XCTAssertTrue(swap.contains("let remote = remoteMatches"), "the matches computed once a render")
        XCTAssertEqual(swap.components(separatedBy: "remoteMatches").count - 1, 2, "declared, and read once in body")
        XCTAssertTrue(swap.contains("private var venueListCatchingUp: Bool { !query.isEmpty && Address(query) == nil && env.venueList.isCatchingUp }"),
                      "said only while searching by name, never for a pasted address")
        XCTAssertTrue(swap.contains("if venueListCatchingUp { Paragraph(\"Monad's token list is still loading, so a token may be missing for now.\") }"))
        // With nothing matched, the "no match" footer says it: never two footers stacked.
        XCTAssertTrue(swap.contains("if !remote.isEmpty || (venueListCatchingUp && !noMatch) {"))
        XCTAssertTrue(swap.contains("} else if venueListCatchingUp { Paragraph(\"No token matches yet: Monad's token list is still loading. Paste a contract address to add any Monad token.\")"))
    }

    /// `text` with every run of whitespace, line breaks included, as one space.
    private func squeezed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A fresh install's first read, live on Monad (read-only): every venue from genesis on rpc1, and the metadata on the
    /// app's endpoints, as the app reads them. Prints the time and every request sent, by host and method. Runs only when
    /// DYOR_LIVE_VENUES=1 (network, several minutes).
    func testAFreshInstallReadsEveryVenueInFullLive() async throws {
        guard ProcessInfo.processInfo.environment["DYOR_LIVE_VENUES"] == "1" else { throw XCTSkip("set DYOR_LIVE_VENUES=1") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingForwarder.self]
        let session = URLSession(configuration: configuration)
        let service = VenueTokensService(logsRPC: RPCClient(url: LaunchpadService.defaultLogsRPC, session: session),
                                         multicall: Multicall(rpc: RPCClient(urls: Monad.publicRPCs, session: session, maxBatch: 40)))
        CountingForwarder.reset()
        let started = Date()
        let saves = Saves()
        let live = await service.refresh(tokens: [], checkpoint: 0, logos: { [:] }) { await saves.record($0) }
        let result = try XCTUnwrap(live)
        let seconds = Int(Date().timeIntervalSince(started))
        let saved = await saves.all
        print("VENUES \(result.tokens.count) tokens, checkpoint \(result.checkpoint) of head \(result.head), \(result.dropped.count) dropped, \(saved.count) saves, \(seconds) s")
        let counts = CountingForwarder.counts()
        for name in counts.keys.sorted() { print("VENUES \(name): \(counts[name] ?? 0)") }
        XCTAssertTrue(result.complete, "read to the head in full")
        XCTAssertTrue(result.tokens.contains { $0.symbol == "QT" }, "QT, on its Monday Trade pool")
    }
}

/// A count a stub's answer reads while a test runs.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// The count after this one.
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// Real requests, passed through and counted (`VenueTokensTests`' live read): each HTTP request as "<host> http", each
/// JSON-RPC call in it as "<host> <method>", and each answer's status as "<host> status <code>". Every request names
/// itself in its User-Agent.
final class CountingForwarder: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tally: [String: Int] = [:]
    private static let forward = URLSession(configuration: .ephemeral)
    private var forwarding: URLSessionDataTask?

    static func reset() { lock.lock(); tally = [:]; lock.unlock() }
    static func counts() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return tally }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var forwarded = request
        let body = Self.body(request)
        forwarded.httpBodyStream = nil
        forwarded.httpBody = body
        forwarded.setValue(nil, forHTTPHeaderField: "Content-Length")
        forwarded.setValue("DyorHQ-build17-tests/1.0 (read-only venue list measurement)", forHTTPHeaderField: "User-Agent")
        let decoded = (try? JSONDecoder().decode(JSON.self, from: body)) ?? .null
        let host = request.url?.host() ?? "?"
        Self.lock.lock()
        Self.tally["\(host) http", default: 0] += 1
        for call in decoded.array ?? [decoded] { Self.tally["\(host) \(call["method"].string ?? "?")", default: 0] += 1 }
        Self.lock.unlock()
        forwarding = Self.forward.dataTask(with: forwarded) { [weak self] data, response, error in
            if let status = (response as? HTTPURLResponse)?.statusCode {
                Self.lock.lock(); Self.tally["\(host) status \(status)", default: 0] += 1; Self.lock.unlock()
            }
            guard let self else { return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            if let error { self.client?.urlProtocol(self, didFailWithError: error) } else { self.client?.urlProtocolDidFinishLoading(self) }
        }
        forwarding?.resume()
    }

    override func stopLoading() { forwarding?.cancel() }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
