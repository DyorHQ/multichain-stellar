import BigInt
import XCTest
@testable import DyorKit

/// The finding (speed milestone 2): every wide scan read its window oldest first within its budget (patient: 80 requests,
/// about 4.8M blocks on rpc2) and dropped the flag saying it stopped short, so a window wider than that came back as its
/// OLDEST slice, passed off as the whole — the wallet's NFTs from the chain's first two weeks (no Moment edition ever),
/// a coin launched in the last six days with 0 holders, an older Moment's holders and pool share from its first days.
/// Now a screen's wide scan reads newest first and says what it couldn't read: a coin's holders are a minimum ("+"), its
/// trades the latest ones, and the wallet's NFTs come from its history store's transfers, with no scan of their own.
final class NewestFirstScanTests: XCTestCase {
    private let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    private let token = Address(literal: "0x6666666666666666666666666666666666666666")
    private let curve = Address(literal: "0x4444444444444444444444444444444444444444")
    private let x = Address(literal: "0x1111111111111111111111111111111111111111")
    private let y = Address(literal: "0x2222222222222222222222222222222222222222")
    private let z = Address(literal: "0x3333333333333333333333333333333333333333")

    private static let wide = URL(string: "https://wide.logs-stub.invalid")!
    private static let narrow = URL(string: "https://narrow.logs-stub.invalid")!

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        super.tearDown()
    }

    /// A client on a logs router (mainnet's path) over stub endpoints: one answering 10,000 blocks in batches of 6, one
    /// 1,000 a request, both refusing a range past their head (an endpoint that clamps is `LogsRouterTests`'). A patient
    /// scan's 80 requests read 4.8M blocks.
    private func routed() -> RPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let session = URLSession(configuration: configuration)
        let router = LogsRouter(endpoints: [LogsEndpoint(url: Self.wide, span: 10_000, clamps: false), LogsEndpoint(url: Self.narrow, span: 1_000, batch: 1, clamps: false)],
                                session: session, gate: LogsGate(inFlight: 8, interval: .zero))
        return RPCClient(logsRouter: router, session: session)
    }

    /// A transfer of `amount` of `token` from `from` to `to` at `block`.
    private func transfer(_ from: Address, _ to: Address, _ amount: Int, at block: UInt64, of coin: Address? = nil) -> Log {
        Log(address: coin ?? token, topics: [transferTopic, from.data.leftPadded(to: 32), to.data.leftPadded(to: 32)], data: BigUInt(amount).word,
            blockNumber: block, transactionHash: Data(repeating: UInt8(block % 251), count: 32), logIndex: Int(block % 7))
    }

    // MARK: The order a scan reads in

    /// A window wider than the budget: oldest first (the default, as every screen read in build 22) holds its first 4.8M
    /// blocks; newest first, its last 4.8M — the newest log, never the oldest. Both say the window wasn't read whole.
    func testAWindowWiderThanTheBudgetIsReadNewestFirstAndSaysSo() async {
        let logs = [transfer(x, y, 1, at: 100), transfer(x, y, 1, at: 5_999_000)]
        LogsStub.install(head: 6_000_000, logs: logs) { _ in nil }
        let up = await routed().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 1, toBlock: 6_000_000)
        XCTAssertEqual(up.logs.map(\.blockNumber), [100], "oldest first: the window's first weeks")
        XCTAssertFalse(up.complete)

        LogsStub.install(head: 6_000_000, logs: logs) { _ in nil }
        let down = await routed().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 1, toBlock: 6_000_000, order: .descending)
        XCTAssertEqual(down.logs.map(\.blockNumber), [5_999_000], "newest first: the latest blocks")
        XCTAssertFalse(down.complete)

        LogsStub.install(head: 6_000_000, logs: logs) { _ in nil }
        let newest = await routed().newestLogs(address: token, topics: [transferTopic], fromBlock: 1, toBlock: 6_000_000)
        XCTAssertEqual(newest.readFrom, 1_200_001, "80 requests of six 10,000-block ranges, down from the head")
        XCTAssertEqual(newest.logs.map(\.blockNumber), [5_999_000])
        XCTAssertFalse(newest.complete)
    }

    /// The newest logs are those of the run read in one piece down from the window's end: below a gap nothing counts (a
    /// wallet's transfers in on one side and out on the other would read as a balance it doesn't have), and with the end
    /// itself unread there is nothing to stand on.
    func testTheNewestLogsStopAtTheFirstGapDownFromTheEnd() {
        let logs = [transfer(x, y, 1, at: 100), transfer(x, y, 1, at: 500), transfer(x, y, 1, at: 900)]
        let gapped = NewestLogs(LogsRead(logs: logs, covered: [1...200, 400...1_000], requests: 2), from: 1, to: 1_000)
        XCTAssertEqual(gapped.readFrom, 400)
        XCTAssertEqual(gapped.logs.map(\.blockNumber), [500, 900])
        XCTAssertFalse(gapped.complete)
        let whole = NewestLogs(LogsRead(logs: logs, covered: [1...1_000], requests: 1), from: 1, to: 1_000)
        XCTAssertEqual(whole.readFrom, 1)
        XCTAssertEqual(whole.logs.map(\.blockNumber), [100, 500, 900])
        XCTAssertTrue(whole.complete)
        let headless = NewestLogs(LogsRead(logs: logs, covered: [1...800], requests: 1), from: 1, to: 1_000)
        XCTAssertNil(headless.readFrom)
        XCTAssertEqual(headless.logs, [])
        XCTAssertFalse(headless.complete)
    }

    /// Off the router (a local fork), a window is cut from its end down, each range whole but the oldest, and the logs come
    /// back in block order whichever end was read first.
    func testOffTheRouterAWindowIsCutFromItsEndDown() async {
        let down = RPCClient.logRanges(address: token, topics: [transferTopic], from: 5, to: 250_004, chunk: 100_000, order: .descending)
        XCTAssertEqual(down.map { [$0.fromBlock, $0.toBlock] }, [[150_005, 250_004], [50_005, 150_004], [5, 50_004]])
        let up = RPCClient.logRanges(address: token, topics: [transferTopic], from: 5, to: 250_004, chunk: 100_000, order: .ascending)
        XCTAssertEqual(up.map { [$0.fromBlock, $0.toBlock] }, [[5, 100_004], [100_005, 200_004], [200_005, 250_004]])
        XCTAssertEqual(RPCClient.logRanges(address: token, topics: [transferTopic], from: 7, to: 7, chunk: 100_000, order: .descending).map(\.toBlock), [7])

        let blocks: [UInt64] = [5, 500_000, 999_999]
        LogsStub.install(head: 1_000_000, logs: blocks.map { transfer(x, y, 1, at: $0) }) { _ in nil }
        let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 999_999, order: .descending)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), blocks, "in block order")
        XCTAssertEqual(LogsStub.queries().first, LogsStub.Range(from: 900_000, to: 999_999), "the newest range asked first")
    }

    // MARK: A launch coin's holders and trades

    /// Of the transfers from some block to the head, an address left with more in than out holds the coin now, whatever
    /// it held before: the count is a minimum, never more than the holders. Of every transfer, it is their number.
    func testAHolderCountFromTheNewestTransfersIsAMinimum() {
        let all = [transfer(.zero, curve, 1_000, at: 10), transfer(curve, x, 10, at: 20), transfer(curve, y, 5, at: 30), transfer(y, z, 5, at: 40),
                   transfer(x, z, 3, at: 50)]
        let whole = LaunchpadService.holders(NewestLogs(logs: all, readFrom: 1, complete: true), excluding: [curve])
        XCTAssertEqual(whole, HolderCount(count: 2, complete: true), "x (7) and z (8); y sold all, the curve is left out")
        // Read down to block 35 only: z's 5 in and x's 3 out → z counted (a holder), x not (it holds 7, unseen): a minimum.
        let newest = LaunchpadService.holders(NewestLogs(logs: all.filter { $0.blockNumber >= 35 }, readFrom: 35, complete: false), excluding: [curve])
        XCTAssertEqual(newest, HolderCount(count: 1, complete: false))
        XCTAssertLessThanOrEqual(newest?.count ?? .max, whole?.count ?? 0)
        XCTAssertNil(LaunchpadService.holders(NewestLogs(logs: [], readFrom: nil, complete: false), excluding: [curve]), "nothing read: no count, never 0")
    }

    /// The service reads a coin's transfers from its launch, newest first: a coin a few hours old is read whole and its
    /// count is exact; one older than the budget reaches back gets a minimum, from its newest transfers, never a count of
    /// its oldest (build 22 read the oldest 4.8M of the last 6.48M blocks, and gave a coin launched since 0 holders).
    func testACoinsHoldersAreReadFromItsLaunchNewestFirst() async throws {
        let head: UInt64 = 110_000_000
        let now = 1_790_000_000 // the stub's head timestamp
        let young = [transfer(.zero, curve, 1_000, at: 109_970_000), transfer(curve, x, 10, at: 109_980_000), transfer(curve, y, 5, at: 109_990_000),
                     transfer(y, z, 5, at: 109_995_000)]
        LogsStub.install(head: head, logs: young) { _ in nil }
        let service = LaunchpadService(rpc: LogsStub.rpc(), addresses: .monadMainnet, logsRPC: routed(), clock: BlockClock(rpc: LogsStub.rpc(), measured: 0.3))
        let fresh = await service.holders(token: token, excluding: [curve], launchedAt: now - 3_600)
        XCTAssertEqual(fresh, HolderCount(count: 2, complete: true))
        let launch = LaunchpadService.launchBlock(launchedAt: now - 3_600, anchor: BlockHeader(number: head, timestamp: now), secondsPerBlock: 0.3)
        XCTAssertEqual(launch, head - 35_000, "an hour a quarter longer (15,000 blocks at 0.3 s) and the 20,000-block margin")
        XCTAssertEqual(LogsStub.queries().map(\.from).min(), launch, "from the launch, not 6.48M blocks back")

        // Forty days old: its window runs from the first launchpad's block (103.5M), 6.46M blocks, past the budget.
        let old = [transfer(.zero, curve, 1_000, at: 103_600_000), transfer(curve, x, 10, at: 104_000_000), transfer(x, y, 4, at: 109_900_000)]
        LogsStub.install(head: head, logs: old) { _ in nil }
        let agedRead = await service.holders(token: token, excluding: [curve], launchedAt: now - 40 * 86_400)
        let aged = try XCTUnwrap(agedRead)
        XCTAssertFalse(aged.complete)
        XCTAssertEqual(aged.count, 1, "y, from the newest transfers; x's balance is older than the read: a minimum of the 2")
        XCTAssertEqual(LogsStub.queries().map(\.to).max(), head, "the head first")
        XCTAssertGreaterThan(LogsStub.queries().map(\.from).min() ?? 0, 104_000_000, "the oldest blocks are the ones left unread")
    }

    /// The trades of a read that stopped short are those of the run read down from the head, of both sides down to the later
    /// of where each stopped: every fill from that block to now, never a scatter, and said to be a part. A side whose head
    /// wasn't read leaves nothing to stand on: no read at all (nil), which the page takes for a failed read — its last good
    /// trades, chart and 24h volume kept — never an empty one that wiped them and showed a volume of 0.
    func testTradesReadInPartAreTheLatestOnesAndSaySo() throws {
        let pair = PairInfo(address: Address(literal: "0x7777777777777777777777777777777777777777"), symbol: "USDC", decimals: 6, isNative: false)
        func fill(_ topic: Data, at block: UInt64) -> Log {
            Log(address: curve, topics: [topic, x.data.leftPadded(to: 32), x.data.leftPadded(to: 32)],
                data: try! ABI.encode([.uint(1_000_000), .uint(BigUInt(10).power(18)), .uint(0), .uint(0)], "uint256,uint256,uint256,uint256"),
                blockNumber: block, transactionHash: Data(repeating: UInt8(block % 251), count: 32), logIndex: 0)
        }
        let anchor = BlockHeader(number: 1_000, timestamp: 1_790_000_000)
        let buys = NewestLogs(logs: [fill(LaunchpadABI.Events.buyTopic, at: 600), fill(LaunchpadABI.Events.buyTopic, at: 900)], readFrom: 500, complete: false)
        let sells = NewestLogs(logs: [fill(LaunchpadABI.Events.sellTopic, at: 800), fill(LaunchpadABI.Events.sellTopic, at: 950)], readFrom: 700, complete: true)
        let read = try XCTUnwrap(LaunchpadService.trades(buys: buys, sells: sells, anchor: anchor, pair: pair, secondsPerBlock: 0.3))
        XCTAssertEqual(read.trades.map(\.block), [800, 900, 950], "the buy at 600 is below where the sells were read from")
        XCTAssertEqual(read.trades.map(\.isBuy), [false, true, false])
        XCTAssertFalse(read.complete)
        let whole = try XCTUnwrap(LaunchpadService.trades(buys: NewestLogs(logs: buys.logs, readFrom: 1, complete: true),
                                                          sells: NewestLogs(logs: sells.logs, readFrom: 1, complete: true), anchor: anchor, pair: pair, secondsPerBlock: 0.3))
        XCTAssertEqual(whole.trades.map(\.block), [600, 800, 900, 950])
        XCTAssertTrue(whole.complete, "complete when both sides are")
        let unread = NewestLogs(logs: [], readFrom: nil, complete: false)
        XCTAssertNil(LaunchpadService.trades(buys: unread, sells: sells, anchor: anchor, pair: pair, secondsPerBlock: 0.3), "the buys' head unread")
        XCTAssertNil(LaunchpadService.trades(buys: buys, sells: unread, anchor: anchor, pair: pair, secondsPerBlock: 0.3), "the sells' head unread")
    }

    /// The service reads the head from the endpoints its logs come from (a node of them behind the app's own endpoint
    /// refused the newest range), and gives no trades at all when either side's newest range couldn't be read.
    func testTheTradesAreReadToTheLogsEndpointsHeadAndNilWhenItsRangeIsUnread() async throws {
        let pair = PairInfo(address: Address(literal: "0x7777777777777777777777777777777777777777"), symbol: "USDC", decimals: 6, isNative: false)
        // The app's endpoint is ahead: its head would be past every node of the logs endpoints.
        LogsStub.install(head: 2_000_000, answer: { host, method, _ in
            host == "rpc.ahead.invalid" && method == "eth_getBlockByNumber"
                ? .object(["number": .string(BigUInt(2_000_100).hexQuantity), "timestamp": .string(BigUInt(1_790_000_000).hexQuantity)]) : nil
        }) { _ in nil }
        let service = LaunchpadService(rpc: LogsStub.rpc(url: URL(string: "https://rpc.ahead.invalid")!), addresses: .monadMainnet, logsRPC: routed(),
                                       clock: BlockClock(rpc: LogsStub.rpc(), measured: 0.4))
        let read = await service.trades(curve: curve, pair: pair)
        XCTAssertEqual(read, CurveTrades(trades: [], complete: true), "no fills in the last day, every block of it read")
        XCTAssertEqual(LogsStub.queries().map(\.to).max(), 2_000_000, "to the logs endpoints' head, not the app endpoint's")

        // The newest range refused every time (a node past which nothing is answered): no read, never "no trades".
        let pastHead = LogsStub.Failure.error(code: -32602, message: "block range extends beyond current head block")
        LogsStub.install(head: 2_000_000) { range in range.to == 2_000_000 ? pastHead : nil }
        let refused = await service.trades(curve: curve, pair: pair)
        XCTAssertNil(refused)
    }

    /// A newest range refused for ending past the answering node's head is asked again after a pause, then twice that,
    /// uncounted, before it counts as a refusal: three refusals in a row from a node a few blocks behind no longer leave
    /// it a gap — and with it the whole read, which stands on its newest range (`NewestLogs`).
    func testANewestRangePastANodesHeadIsAskedAgainAfterAPause() async {
        let pastHead = LogsStub.Failure.error(code: -32602, message: "block range extends beyond current head block")
        let refusals = AskCount()
        LogsStub.install(head: 1_000_000, logs: [transfer(x, y, 1, at: 995_000), transfer(x, y, 1, at: 999_990)]) { range in
            range.to == 1_000_000 && refusals.next() <= 3 ? pastHead : nil
        }
        let started = ContinuousClock.now
        let read = await routed().newestLogs(address: token, topics: [transferTopic], fromBlock: 950_001, toBlock: 1_000_000)
        XCTAssertEqual(read.readFrom, 950_001)
        XCTAssertTrue(read.complete)
        XCTAssertEqual(read.logs.map(\.blockNumber), [995_000, 999_990])
        XCTAssertEqual(refusals.count, 4, "refused three times, answered the fourth")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .seconds(3), "asked again after 1 s, then after 2 s")
    }

    // MARK: A Moment's holders

    /// A Moment coin's holder statistics from a read that stopped short of its publish: the holders a minimum, the read
    /// said to be a part (the screen then hides the top wallet and the pool's share); nothing read, no statistics at all.
    func testAMomentsHolderStatsFromAPartSayTheyAreAPart() throws {
        let addresses = V2Fixture.moments
        let coin = Address(literal: "0x5555555555555555555555555555555555555555")
        let all = [transfer(.zero, addresses.poolManager, 60, at: 1, of: coin), transfer(.zero, x, 30, at: 2, of: coin), transfer(.zero, y, 10, at: 3, of: coin),
                   transfer(x, y, 5, at: 4, of: coin)]
        let whole = try XCTUnwrap(MomentsService.holderStats(NewestLogs(logs: all, readFrom: 1, complete: true), addresses: addresses, scannedTo: 4))
        XCTAssertEqual(whole.holders, 2)
        XCTAssertTrue(whole.complete)
        let part = try XCTUnwrap(MomentsService.holderStats(NewestLogs(logs: all.filter { $0.blockNumber >= 4 }, readFrom: 4, complete: false), addresses: addresses, scannedTo: 4))
        XCTAssertEqual(part.holders, 1, "y, seen receiving; x's balance is older than the read")
        XCTAssertLessThanOrEqual(part.holders, whole.holders)
        XCTAssertFalse(part.complete)
        XCTAssertNil(MomentsService.holderStats(NewestLogs(logs: [], readFrom: nil, complete: false), addresses: addresses, scannedTo: 4))
        XCTAssertTrue(MomentsService.holderStats(transfers: all, addresses: addresses, scannedTo: 4).complete, "a caller's full list is complete")
    }

    // MARK: The wallet's NFTs

    private let wallet = Address(literal: "0x00000000000000000000000000000000000a11ce")
    private let collectionA = Address(literal: "0x00000000000000000000000000000000000000aa")
    private let collectionB = Address(literal: "0x00000000000000000000000000000000000000bb")

    /// An ERC-721 `Transfer` into the wallet: four topics, the token id indexed, no data.
    private func edition(_ collection: Address, _ id: Int, at block: UInt64) -> Log {
        Log(address: collection, topics: [transferTopic, x.data.leftPadded(to: 32), wallet.data.leftPadded(to: 32), BigUInt(id).word], data: Data(),
            blockNumber: block, transactionHash: Data(repeating: UInt8(block % 251), count: 32), logIndex: 0)
    }

    /// The transfers into the wallet the history store holds: #1 and #2 of A, #7 of B, #1 of A again (an older transfer),
    /// and an ERC-20's transfer (three topics).
    private var incoming: [Log] {
        [edition(collectionA, 1, at: 100), edition(collectionA, 2, at: 200), edition(collectionB, 7, at: 300), transfer(x, wallet, 5, at: 400), edition(collectionA, 1, at: 50)]
    }

    /// The candidates are the ERC-721 transfers, newest first, each NFT once; an ERC-20's never.
    func testTheNFTCandidatesAreTheEditionTransfersNewestFirst() {
        let candidates = WalletNFTDiscovery.candidates(incoming)
        XCTAssertEqual(candidates.map(\.contract), [collectionB, collectionA, collectionA])
        XCTAssertEqual(candidates.map(\.tokenId), [7, 2, 1])
    }

    /// The chain: A #1, #3 and #4 and B #7 are the wallet's, A #2 and every A from #1,001 someone else's; A's name and #1's
    /// on-chain metadata answer, B's token URI is empty. `starving`: collections whose `ownerOf` burns the gas of the read
    /// it is in, so every call after it fails too, as Multicall3 reports a starved call (`MomentsChainStub`).
    private func installCollections(breakingOwnership: Bool = false, starving: Set<Address> = []) -> Multicall {
        let wallet = wallet, x = x, a = collectionA
        MomentsChainStub.install({ to, data in
            let selector = data.prefix(4)
            let args = ABIWords(data.dropFirst(4))
            if selector == StubSelector.of("ownerOf(uint256)") {
                let id = args.uint(0) ?? 0
                return try! ABI.encode([.address(to == a && (id == 2 || id > 1_000) ? x : wallet)], "address")
            }
            if selector == StubSelector.of("name()") { return try! ABI.encode([.string(to == a ? "Alpha" : "Beta")], "string") }
            if selector == StubSelector.of("tokenURI(uint256)") {
                let document = "data:application/json;base64," + Data(#"{"name":"Alpha One"}"#.utf8).base64EncodedString()
                return try! ABI.encode([.string(to == a ? document : "")], "string")
            }
            return nil
        }, breakingSelectors: breakingOwnership ? [StubSelector.of("ownerOf(uint256)")] : [], starving: starving)
        return Multicall(rpc: MomentsChainStub.rpc())
    }

    /// The ownership reads `MomentsChainStub` was asked, as the number of `ownerOf` calls in each.
    private func ownershipReads() -> [Int] {
        let ownerOf = StubSelector.of("ownerOf(uint256)").hexString
        return MomentsChainStub.batches().map { $0.filter { $0.selector == ownerOf }.count }.filter { $0 > 0 }
    }

    /// The NFTs come from the history store's transfers, with no scan of their own: those the wallet still owns, newest
    /// first, named from their metadata (else their collection and id), complete when the transfers were.
    func testTheWalletsNFTsComeFromItsHistoryWithNoScan() async {
        let discovery = WalletNFTDiscovery(multicall: installCollections())
        let held = await discovery.held(wallet: wallet, incoming: incoming, complete: true)
        XCTAssertEqual(held.nfts.map(\.id), ["\(collectionB.hex)-7", "\(collectionA.hex)-1"], "A #2 isn't the wallet's")
        XCTAssertEqual(held.nfts.map(\.name), ["Beta #7", "Alpha One"])
        XCTAssertTrue(held.complete)
        XCTAssertFalse(held.cut)
        XCTAssertEqual(MomentsChainStub.logQueries(), [], "no log scan")

        let filling = await discovery.held(wallet: wallet, incoming: incoming, complete: false)
        XCTAssertEqual(filling.nfts.count, 2)
        XCTAssertFalse(filling.complete, "the transfers still being read: an NFT may be missing")

        let capped = await discovery.held(wallet: wallet, incoming: incoming, complete: true, limit: 1)
        XCTAssertEqual(capped.nfts.map(\.tokenId), [7])
        XCTAssertTrue(capped.cut, "more may be held than are listed")
        XCTAssertTrue(capped.complete)

        // 130 editions of A the wallet no longer holds (ids from 1,001), newest first: past the check limit the rest aren't
        // asked after, and the list says one may be missing rather than "no NFTs".
        let spam = (1...130).map { edition(collectionA, 1_000 + $0, at: UInt64(1_000 + $0)) }
        let checked = await discovery.held(wallet: wallet, incoming: spam, complete: true, checkLimit: 120)
        XCTAssertEqual(checked.nfts, [])
        XCTAssertFalse(checked.complete)
    }

    /// The speed review's finding (2026-10-09): a call that failed inside an aggregate that answered was taken for "not
    /// held", but Multicall3 reports a call starved of gas by an earlier one exactly as a revert, so a spam edition that
    /// burns the read's gas, newest in the batch, dropped the wallet's own NFTs after it from a list said to be complete.
    /// The failed calls are read again — the first on its own, the rest together — and only a call that fails read on its
    /// own is "not held". Past the re-read budget they are unread: the list keeps what the last read showed of them, and
    /// says one may be missing.
    func testAnNFTStarvedOfGasByASpamEditionIsReadAgainNotDropped() async {
        let spam = Address(literal: "0x00000000000000000000000000000000000000cc")
        let incoming = [edition(collectionA, 1, at: 100), edition(collectionB, 7, at: 300), edition(spam, 1, at: 500)]
        let discovery = WalletNFTDiscovery(multicall: installCollections(starving: [spam]))
        let held = await discovery.held(wallet: wallet, incoming: incoming, complete: true)
        XCTAssertEqual(held.nfts.map(\.id), ["\(collectionB.hex)-7", "\(collectionA.hex)-1"], "the spam edition, alone, isn't the wallet's")
        XCTAssertTrue(held.complete)
        XCTAssertEqual(ownershipReads(), [3, 1, 2], "the batch; the first that failed, on its own; the others together")

        // No re-reads left: the three are unread, the list keeps what the last read showed, and says one may be missing.
        let shown = NFTAsset(contract: collectionA, tokenId: 1, collection: "Alpha", name: "Alpha One", imageURL: nil, animationURL: nil)
        let budgetless = WalletNFTDiscovery(multicall: installCollections(starving: [spam]))
        let unread = await budgetless.held(wallet: wallet, incoming: incoming, complete: true, keeping: [shown], rereads: 0)
        XCTAssertEqual(unread.nfts, [shown])
        XCTAssertFalse(unread.complete)
        XCTAssertEqual(ownershipReads(), [3])
    }

    /// The finding: with `limit` reached at a batch's end, the next batch's ownership read was sent, and thrown away, and
    /// the list said more were held than it shows. Now no further batch is read: candidates never asked after only say
    /// more may be held ("N+"), and a list with none left is whole.
    func testALimitReachedAtABatchsEndReadsNoFurtherBatch() async {
        // Newest first: A #3 and #4 (the wallet's), then #1,001 and #1,002 (someone else's).
        let incoming = [edition(collectionA, 1_002, at: 100), edition(collectionA, 1_001, at: 200), edition(collectionA, 4, at: 300), edition(collectionA, 3, at: 400)]
        let discovery = WalletNFTDiscovery(multicall: installCollections())
        let capped = await discovery.held(wallet: wallet, incoming: incoming, complete: true, limit: 2, batch: 2)
        XCTAssertEqual(capped.nfts.map(\.tokenId), [3, 4])
        XCTAssertTrue(capped.cut, "two candidates never asked after: one may be held")
        XCTAssertTrue(capped.complete)
        XCTAssertEqual(ownershipReads(), [2], "no read of the next batch")

        // Nothing left after the limit: the list is whole.
        let exact = WalletNFTDiscovery(multicall: installCollections())
        let whole = await exact.held(wallet: wallet, incoming: Array(incoming.suffix(2)), complete: true, limit: 2, batch: 2)
        XCTAssertEqual(whole.nfts.map(\.tokenId), [3, 4])
        XCTAssertFalse(whole.cut)
        // The limit reached inside a batch with one more held after it: more are held than are listed.
        let inside = WalletNFTDiscovery(multicall: installCollections())
        let more = await inside.held(wallet: wallet, incoming: [edition(collectionA, 1, at: 50)] + incoming.suffix(2), complete: true, limit: 2, batch: 3)
        XCTAssertEqual(more.nfts.map(\.tokenId), [3, 4])
        XCTAssertTrue(more.cut)
    }

    /// An ownership read that fails keeps the NFTs the last read showed, and says the list may be missing one: never an
    /// empty list for a read that failed, nor an NFT shown as held that wasn't before.
    func testAFailedOwnershipReadKeepsTheLastGoodNFTs() async {
        let shown = NFTAsset(contract: collectionA, tokenId: 1, collection: "Alpha", name: "Alpha One", imageURL: nil, animationURL: nil)
        let discovery = WalletNFTDiscovery(multicall: installCollections(breakingOwnership: true))
        let held = await discovery.held(wallet: wallet, incoming: incoming, complete: true, keeping: [shown])
        XCTAssertEqual(held.nfts, [shown])
        XCTAssertFalse(held.complete)
        let none = await discovery.held(wallet: wallet, incoming: incoming, complete: true)
        XCTAssertEqual(none.nfts, [])
        XCTAssertFalse(none.complete, "nothing kept, and said to be unread")
        let empty = await discovery.held(wallet: wallet, incoming: [], complete: true)
        XCTAssertEqual(empty, WalletNFTDiscovery.Held(nfts: [], complete: true))
    }
}

/// The screens that show what the newest-first reads give, read from the app's sources (squeezed: every run of whitespace
/// one space): each figure is "—" until read, a minimum ("+") when the read stopped short, a failed read says so with Retry
/// and keeps the last good figure, a minimum no read could better says so plainly, with no error and no Retry, and a
/// page's reads are its own task, cancelled with it. Reverting any of these lines fails here.
final class NewestFirstScreenPinTests: XCTestCase {
    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func source(_ path: String) throws -> String { squeezed(try DocsLinksTests.appSource(path)) }

    /// My Holdings' NFTs: never "No NFTs" on a read that was a part or not made yet, a count that may be missing one is a
    /// minimum, "Reading your history" only while this wallet's history reads its window (else Retry), and the transfers'
    /// reach said when they start after the chain's first block.
    func testTheNFTsTabNeverPassesAPartOffAsTheWhole() throws {
        let assets = try Self.source("Portfolio/AssetsModel.swift")
        XCTAssertTrue(assets.contains("if kind == .nfts, let gap = model.nftGap {"))
        XCTAssertTrue(assets.contains("if !model.nftsFilling { Button(\"Retry\", systemImage: \"arrow.clockwise\", action: retry)"))
        XCTAssertTrue(assets.contains("if kind == .nfts, model.nfts.isEmpty, model.nftsLoading || model.nftGap == nil { Group { if model.nftsLoading || !model.nftsRead { Text(\"Reading the wallet…\") } "
                                      + "else if let day = model.nftsSinceDay { // Read back to a day, not the chain's start: says how far, never \"No NFTs in this wallet\". "
                                      + "Paragraph(verbatim: tr(\"No NFTs received since \\(day).\")).multilineTextAlignment(.center) } else { Text(\"No NFTs in this wallet yet.\") } }"))
        XCTAssertTrue(assets.contains("if kind == .nfts, !model.nfts.isEmpty, !model.nftsLoading, model.nftGap == nil, let day = model.nftsSinceDay {"))
        XCTAssertTrue(assets.contains("Paragraph(verbatim: tr(\"Only NFTs received since \\(day) are listed.\"))"))
        XCTAssertTrue(assets.contains("Text(verbatim: model.nftCount)"))
        XCTAssertTrue(assets.contains("nftsComplete && !nftsCut && nftsSince == nil ? \"\\(nfts.count)\" : \"\\(nfts.count)+\""))
        // The NFTs come from this wallet's history only, and "reading" is that history reading its window.
        XCTAssertTrue(assets.contains("let ownHistory = env.history.wallet == address let history = ownHistory ? env.history.snapshot : .empty"))
        XCTAssertTrue(assets.contains("nftsFilling = ownHistory && !held.complete && history.readingWindow(scans: WalletHistoryScans.holdings)"))
        XCTAssertTrue(assets.contains("nftsProgress = history.progress(since: nil, scans: WalletHistoryScans.holdings)"))
        XCTAssertTrue(assets.contains("if nftsFilling { return tr(\"Reading your history… \\(NumberStyle.percent(nftsProgress * 100,"))
        XCTAssertTrue(assets.contains("floor > 0 ? history.anchor.map { BlockClock.time(of: floor, anchor: $0, secondsPerBlock: history.secondsPerBlock) } : nil"))
        // Read again once the transfers are read in full, and once they reach further back than the NFTs were read from.
        let portfolio = try Self.source("Portfolio/PortfolioView.swift")
        XCTAssertTrue(portfolio.contains(".task(id: \"\\(transfersIn.complete)-\\(transfersIn.floor.map(String.init) ?? \"\")\") { "
                                         + "if transfersIn.complete, !assets.complete || !assets.nftsComplete || (assets.nftsRead && assets.nftsFloor != transfersIn.floor) {"))
        // The Update screen lists balances only: no NFTs read for it.
        XCTAssertTrue(try Self.source("App/UpdateGate.swift").contains("await assets.load(env: env, address: session.address, force: false, nfts: false)"))
        // The NFTs scan nothing of their own: the history store's transfers.
        XCTAssertTrue(try Self.source("App/AppEnvironment.swift").contains("nftDiscovery = WalletNFTDiscovery(multicall: multicall)"))
        // A cut cohort list is completed from the history store's Moments history once it is read in full.
        let cohorts = try Self.source("Portfolio/PastCohortsCard.swift")
        XCTAssertTrue(cohorts.contains("let history = env.history.wallet == address && snapshot.status(WalletHistoryScans.momentsId).complete ? snapshot.moments : nil"))
        XCTAssertTrue(cohorts.contains("try await cohort.positions(account: address, history: history)"))
    }

    /// A launch's page: the 24h volume "—" until read and a minimum while read in part; the holders "—" until read, "N+"
    /// for a minimum and "—" for a minimum of none; a failed read says so with Retry (and, with nothing read yet, not
    /// "part of"); a minimum no read could better is a plain note; Retry and a done trade or claim read the page again as
    /// its own task.
    func testALaunchPageSaysWhatItReadAndReadsAsItsOwnTask() throws {
        let launch = try Self.source("Launchpad/LaunchpadView.swift")
        XCTAssertTrue(launch.contains("if holders.complete { return \"\\(holders.count)\" } return holders.count > 0 ? \"\\(holders.count)+\" : \"—\""))
        XCTAssertTrue(launch.contains("if tradesRead { InlineError(message: \"Part of this coin's trades couldn't be read just now, so the chart and 24h volume may be missing some.\") } "
                                      + "else { InlineError(message: \"This coin's trades couldn't be read just now.\") }"))
        XCTAssertTrue(launch.contains("if holdersUnread { HStack(alignment: .firstTextBaseline) { InlineError(message: \"This coin's holders couldn't be read just now.\")"))
        XCTAssertTrue(launch.contains("} else if let holders, !holders.complete {"))
        XCTAssertTrue(launch.contains("Paragraph(\"Counted from this coin's most recent transfers only, so there may be more holders.\") .font(.footnote).foregroundStyle(.secondary)"))
        XCTAssertFalse(launch.contains("so the holder count is a minimum"), "a minimum is no failure")
        XCTAssertTrue(launch.contains(".task(id: reloads) { await load() }"))
        XCTAssertEqual(launch.components(separatedBy: "Button(\"Retry\") { reloads += 1 }").count - 1, 3, "the detail, the trades and the holders")
        XCTAssertEqual(launch.components(separatedBy: "onDone: { reloads += 1 }").count - 1, 3, "graduation and both claims")
        XCTAssertEqual(launch.components(separatedBy: "onDone: { amountText = \"\"; reloads += 1 }").count - 1, 2, "a buy and a sell")
        XCTAssertFalse(launch.contains("Task { await load() }"), "no read outlives the page")
        XCTAssertTrue(launch.contains("let curveTrades = await t"))
    }

    /// A Moment's page: the coin's holders as the launch page has them; the top wallet and the pool's share only from a
    /// whole read; Retry and a done action read the page again as its own task.
    func testAMomentPageSaysWhatItReadAndReadsAsItsOwnTask() throws {
        let moment = try Self.source("Moments/MomentDetailView.swift")
        XCTAssertTrue(moment.contains("LabeledContent(\"Coin holders\", value: coinHoldersText)"))
        XCTAssertTrue(moment.contains("if stats.complete { return \"\\(stats.holders)\" } return stats.holders > 0 ? \"\\(stats.holders)+\" : \"—\""))
        XCTAssertTrue(moment.contains("if let stats = holderStats, stats.complete, stats.holders > 0 { LabeledContent(\"Top wallet\""))
        XCTAssertTrue(moment.contains("if holderStatsUnread { HStack(alignment: .firstTextBaseline) { InlineError(message: \"This coin's holders couldn't be read just now.\") "
                                      + "Spacer(minLength: 8) Button(\"Retry\") { reloads += 1 }"))
        XCTAssertTrue(moment.contains("} else if let stats = holderStats, !stats.complete {"))
        XCTAssertTrue(moment.contains("Paragraph(\"Counted from this coin's most recent transfers only, so there may be more holders.\")"))
        XCTAssertTrue(moment.contains(".task(id: reloads) { await load() }"))
        XCTAssertTrue(moment.contains("private func finished() { reloads += 1 onChanged() }"))
        XCTAssertFalse(moment.contains("Task {"), "no read outlives the page")
        // A failed read keeps the last good statistics; a read that lands replaces the ones kept from the last opening,
        // which show until then, said to be saved.
        XCTAssertTrue(moment.contains("if let stats { holderStats = stats; holderStatsSavedAt = nil } holderStatsUnread = stats == nil"))
        XCTAssertTrue(moment.contains("if holderStats == nil, let saved = await env.moments.savedHolderStats(coin: m.coin) { holderStats = saved.stats holderStatsSavedAt = saved.asOf }"))
        XCTAssertTrue(moment.contains("if let savedAt = holderStatsSavedAt { SavedLine(date: savedAt, reading: !holderStatsUnread) }"))
        // The edition holders: "—" until read, a failure in the header with Retry, a minimum past the editions one read counts.
        XCTAssertTrue(moment.contains("LabeledContent(\"Edition holders\", value: editionHoldersText)"))
        XCTAssertTrue(moment.contains("guard let editions = editionHolders else { return \"—\" } return editions.complete ? \"\\(editions.holders)\" : \"\\(editions.holders)+\""))
        XCTAssertTrue(moment.contains("if let loadError { HStack(alignment: .firstTextBaseline) { InlineError(message: loadError) Spacer(minLength: 8) Button(\"Retry\") { reloads += 1 }"))
        XCTAssertFalse(moment.contains("nftHolders"), "a failed read is never 0 holders")
    }
}

/// Counts what a stub rule (which may run on any thread) is asked.
private final class AskCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    /// The next count: 1 the first time.
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
