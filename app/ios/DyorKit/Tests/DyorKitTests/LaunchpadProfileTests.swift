import BigInt
import XCTest
@testable import DyorKit

/// My Launchpad never shows a figure as 0 while it is unread: every balance and holder reward comes from one read whose
/// unanswered calls stay unread (`LaunchpadService.holdings`, `LaunchHoldings`), kept from the last read for the same
/// wallet; a holding's profit and loss comes from the wallet's own fills in its history (`LaunchpadWalletHistory.pnl`),
/// and only once the history holds every fill since the coin's launch, up to the block the balance was read at
/// (`WalletHistorySnapshot.fillsCoverage`).
final class LaunchpadProfileTests: XCTestCase {
    private static let account = Address(literal: "0x90f3e7c3B4E32494b06814Fd2F4556671F5F4C47")
    private static let sharing = Address(literal: "0x00000000000000000000000000000000005a1e05")
    private static let coinA = Address(literal: "0x00000000000000000000000000000000000c010a")
    private static let coinB = Address(literal: "0x00000000000000000000000000000000000c010b")
    private static let coinC = Address(literal: "0x00000000000000000000000000000000000c010c")
    private static let curveA = Address(literal: "0x0000000000000000000000000000000000c0e0a0")
    private static let curveB = Address(literal: "0x0000000000000000000000000000000000c0e0b0")

    private static func launch(_ token: Address, curve: Address = curveA, sharesFees: Bool, launchedAt: Int = 1_800_000_000) -> Launch {
        Launch(token: token, curve: curve, deployer: account, creatorFeeRecipient: account, pairToken: .zero, graduationThreshold: 1_000, creatorTaxBps: 0,
               poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: sharesFees, graduationVenue: .monday, phase: .bonding, sweptQuote: 0, sweptTokens: 0, sweptAt: 0,
               poolId: Data(count: 32), name: "Coin", symbol: "C", logo: "", description: "", socials: .none, pair: .mon, price: 0, realQuoteReserve: 0,
               completed: false, rescued: false, launchedAt: launchedAt, supply: 0, marketCap: 0, progressBps: 0)
    }

    private static func uint(_ value: BigUInt) -> Result<[ABIValue], Error> { .success([.uint(value)]) }
    private static let reverted: Result<[ABIValue], Error> = .failure(RPCError(code: -32000, message: "Call reverted", data: "0x"))

    // MARK: Balances and rewards in one read

    /// Each answer is read; a call that failed leaves its coin unread, never 0; a list of the wrong length answers none.
    func testOneReadKeepsEveryUnansweredCallUnread() {
        let read = LaunchpadService.holdings(coins: [Self.coinA, Self.coinB, Self.coinC], sharing: [Self.coinA, Self.coinC],
                                             results: [Self.uint(5), Self.reverted, Self.uint(0), Self.uint(7), Self.reverted])
        XCTAssertEqual(read.balances, [Self.coinA: 5, Self.coinC: 0], "a zero balance is read; a failed one is not")
        XCTAssertEqual(read.balancesUnread, [Self.coinB])
        XCTAssertEqual(read.rewards, [Self.coinA: 7])
        XCTAssertEqual(read.rewardsUnread, [Self.coinC])
        XCTAssertFalse(read.complete)
        XCTAssertTrue(read.balancesMissing, "B was never read")
        XCTAssertTrue(read.rewardsMissing)

        let short = LaunchpadService.holdings(coins: [Self.coinA], sharing: [Self.coinA], results: [Self.uint(5)])
        XCTAssertEqual(short, .unread(coins: [Self.coinA], sharing: [Self.coinA]), "a short answer reads nothing")
        XCTAssertTrue(short.balances.isEmpty)
    }

    /// The service asks every coin's balance and every fee-sharing coin's rewards (on its own stack), and the block they
    /// are read at, in one aggregate — one request, one `aggregate3`, never a call per coin; the calls the chain refuses
    /// come back unread.
    func testTheServiceReadsBalancesAndRewardsInOneAggregate() async throws {
        VenueChainStub.reset(head: BlockHeader(number: 1_000_000, timestamp: 1_800_000_000))
        let addresses = LaunchpadAddresses(factory: Address(literal: "0x00000000000000000000000000000000000fac70"), router: .zero, escrow: .zero,
                                           holderFeeSharing: Self.sharing, hook: .zero, poolManager: .zero, generation: .v2)
        let service = LaunchpadService(rpc: VenueChainStub.rpc(), addresses: addresses)
        func balanceOf(_ coin: Address) -> ContractCall { LaunchpadABI.call(coin, LaunchpadABI.Token.balanceOf, [.address(Self.account)], returns: "uint256") }
        func rewards(_ coin: Address) -> ContractCall { LaunchpadABI.call(Self.sharing, LaunchpadABI.Sharing.pendingRewards, [.address(coin), .address(Self.account)], returns: "uint256") }
        VenueChainStub.answer(Self.coinA, balanceOf(Self.coinA), with: BigUInt(1_120_000).word)
        VenueChainStub.answer(Self.coinB, balanceOf(Self.coinB), with: BigUInt(0).word)
        VenueChainStub.answer(Self.sharing, rewards(Self.coinA), with: BigUInt(42).word)
        // C's balance and rewards are refused: unread.
        let launches = [Self.launch(Self.coinA, sharesFees: true), Self.launch(Self.coinB, sharesFees: false), Self.launch(Self.coinC, sharesFees: true), Self.launch(Self.coinA, sharesFees: true)]
        let held = try await service.holdings(of: launches, account: Self.account)
        XCTAssertEqual(held.balances, [Self.coinA: 1_120_000, Self.coinB: 0])
        XCTAssertEqual(held.balancesUnread, [Self.coinC])
        XCTAssertEqual(held.rewards, [Self.coinA: 42], "B shares no fees: no reward is read for it")
        XCTAssertEqual(held.rewardsUnread, [Self.coinC])
        XCTAssertEqual(held.block, 1_000_000, "the block the aggregate ran at, from Multicall3's getBlockNumber in it")
        let multicalls = VenueChainStub.snapshot.calls.filter { $0.to == Self.sharing || [Self.coinA, Self.coinB, Self.coinC].contains($0.to) }
        XCTAssertEqual(multicalls.count, 5, "each coin once, a coin listed twice asked once")
        XCTAssertEqual(VenueChainStub.snapshot.calls.filter { $0.to == Multicall.address }.map(\.data), [ABI.selector("getBlockNumber()")])
        XCTAssertEqual(VenueChainStub.snapshot.aggregates, 1, "one aggregate")
        XCTAssertEqual(VenueChainStub.snapshot.requests, 1, "one request")

        // A block call that fails names no block (the balances it came with are still read).
        let blockCall = ContractCall(to: Multicall.address, data: ABI.selector("getBlockNumber()"), returns: [.uint(256)])
        XCTAssertNil(Multicall.block(.failure(RPCError(code: -32000, message: "Call reverted", data: "0x"))))
        XCTAssertEqual(Multicall.block(.success([.uint(7)])), 7)
        XCTAssertEqual(Multicall.blockNumber.data, blockCall.data)
    }

    /// A read that didn't answer keeps what the last read for the same wallet had, still marked unread; with none kept it
    /// stays unread. A claimed reward is forgotten, so a failed read after the claim can't bring it back.
    func testTheLastGoodHoldingsAreKeptForTheSameWallet() {
        let previous = LaunchHoldings(balances: [Self.coinA: 9, Self.coinB: 0], rewards: [Self.coinA: 3])
        let failed = LaunchHoldings.unread(coins: [Self.coinA, Self.coinB, Self.coinC], sharing: [Self.coinA])
        let kept = LaunchHoldings.keeping(failed, previous: previous)
        XCTAssertEqual(kept.balances, [Self.coinA: 9, Self.coinB: 0], "kept, never zeroed")
        XCTAssertEqual(kept.rewards, [Self.coinA: 3])
        XCTAssertEqual(kept.balancesUnread, [Self.coinA, Self.coinB, Self.coinC], "still said to be unread")
        XCTAssertTrue(kept.balancesMissing, "C was never read")
        XCTAssertFalse(LaunchHoldings.keeping(LaunchHoldings.unread(coins: [Self.coinA], sharing: []), previous: previous).balancesMissing)
        XCTAssertEqual(LaunchHoldings.keeping(failed, previous: nil), failed, "another wallet's (or none) is never kept")

        let fresh = LaunchHoldings(balances: [Self.coinA: 1], rewards: [Self.coinA: 2])
        XCTAssertEqual(LaunchHoldings.keeping(fresh, previous: previous), fresh, "what a read answered replaces the last read")

        let claimed = kept.claimed([Self.coinA, Self.coinC])
        XCTAssertEqual(claimed.rewards, [Self.coinA: 0], "claimed: nothing waits; a coin never read stays unread")
        XCTAssertEqual(LaunchHoldings.keeping(LaunchHoldings.unread(coins: [], sharing: [Self.coinA]), previous: claimed).rewards[Self.coinA], 0)

        // The block: the read's own, else the last one's (every balance kept is as of it or earlier); a claim keeps it.
        let atBlock = LaunchHoldings(balances: [Self.coinA: 9], rewards: [:], block: 500)
        XCTAssertEqual(LaunchHoldings.keeping(failed, previous: atBlock).block, 500)
        XCTAssertEqual(LaunchHoldings.keeping(LaunchHoldings(balances: [Self.coinA: 1], rewards: [:], block: 600), previous: atBlock).block, 600)
        XCTAssertEqual(atBlock.claimed([Self.coinA]).block, 500)
        XCTAssertNil(LaunchHoldings.keeping(failed, previous: nil).block)
    }

    // MARK: Profit and loss from the wallet's own fills

    private static func fill(_ curve: Address, buy: Bool, quote: BigUInt, block: UInt64 = 109_000_000) -> WalletCurveFill {
        WalletCurveFill(hash: Data(repeating: 1, count: 32), block: block, logIndex: Int(quote % 97), time: Date(), curve: curve, isBuy: buy,
                        quoteAmount: quote, tokenAmount: 1, fee: 0, tax: 0)
    }

    /// What the holding is worth less what the wallet put in on the curve and didn't take out (gross buys less net sells),
    /// at the pair's price today; another curve's fills don't count; no fill, no value or no pair price gives none.
    func testProfitAndLossComesFromTheWalletsOwnFills() throws {
        let e18 = BigUInt(10).power(18)
        let history = LaunchpadWalletHistory(fills: [Self.fill(Self.curveA, buy: true, quote: 10 * e18), Self.fill(Self.curveA, buy: false, quote: 4 * e18),
                                                     Self.fill(Self.curveB, buy: true, quote: 100 * e18)], claims: [])
        let pnl = try XCTUnwrap(history.pnl(curve: Self.curveA, pairDecimals: 18, valueUSD: 9, pairUSD: 2))
        XCTAssertEqual(pnl.usd, 9 - 6 * 2, accuracy: 1e-9, "6 MON in at $2, worth $9 now")
        XCTAssertEqual(try XCTUnwrap(pnl.percent), -3.0 / 12 * 100, accuracy: 1e-9)

        let out = try XCTUnwrap(LaunchpadWalletHistory(fills: [Self.fill(Self.curveA, buy: true, quote: e18), Self.fill(Self.curveA, buy: false, quote: 2 * e18)], claims: [])
            .pnl(curve: Self.curveA, pairDecimals: 18, valueUSD: 1, pairUSD: 1))
        XCTAssertEqual(out.usd, 2, accuracy: 1e-9, "took out more than it put in")
        XCTAssertNil(out.percent, "no cost to measure against")

        XCTAssertNil(history.pnl(curve: Address(literal: "0x0000000000000000000000000000000000c0e0c0"), pairDecimals: 18, valueUSD: 9, pairUSD: 2), "bought elsewhere: no curve cost")
        XCTAssertNil(history.pnl(curve: Self.curveA, pairDecimals: 18, valueUSD: nil, pairUSD: 2), "no value")
        XCTAssertNil(history.pnl(curve: Self.curveA, pairDecimals: 18, valueUSD: 9, pairUSD: 0), "no pair price")
        XCTAssertNil(history.pnl(curve: Self.curveA, pairDecimals: 18, valueUSD: 9, pairUSD: nil))
        // A 6-decimal pair counts its own units.
        let usdc = LaunchpadWalletHistory(fills: [Self.fill(Self.curveA, buy: true, quote: 5_000_000)], claims: [])
        XCTAssertEqual(try XCTUnwrap(usdc.pnl(curve: Self.curveA, pairDecimals: 6, valueUSD: 6, pairUSD: 1)).usd, 1, accuracy: 1e-9)
    }

    // MARK: Shown only once every fill since the launch is held

    private static let head = BlockHeader(number: 111_714_154, timestamp: 1_800_000_000)
    private static let now = Date(timeIntervalSince1970: 1_800_000_060)

    private static func snapshot(complete: Bool = false, progress: Double = 0.35, reachedChain: Bool = true, coveredFrom: UInt64?, updated: Date? = now,
                                 curves: Set<Address> = [curveA]) -> WalletHistorySnapshot {
        var snapshot = WalletHistorySnapshot.empty
        snapshot.anchor = head
        snapshot.curves = curves
        snapshot.status[WalletHistoryScans.launchpadId] = HistoryStatus(complete: complete, progress: progress, reachedChain: reachedChain, updatedAt: updated,
                                                                        floor: LaunchpadAddresses.feeHistoryStart, head: head.number, coveredFrom: coveredFrom)
        return snapshot
    }

    /// The store reads newest first: a coin launched a day ago has every fill held long before the scan reaches its floor,
    /// and its profit and loss is final then; an older coin's waits; a scan that stalled is unread; a curve the fills
    /// weren't matched to waits for the history to be built again with it; with no balance block, a scan not refreshed
    /// lately waits too.
    func testProfitAndLossWaitsForEveryFillSinceTheLaunch() {
        let pace = BlockClock.fallbackSecondsPerBlock
        let dayOld = 1_800_000_000 - 86_400
        let dayBlocks = BlockClock.blocks(in: 86_400, secondsPerBlock: pace)
        func coverage(_ snapshot: WalletHistorySnapshot, launchedAt: Int = dayOld, through block: UInt64? = nil) -> HistoryCoverage {
            snapshot.fillsCoverage(curve: Self.curveA, launchedAt: launchedAt, secondsPerBlock: pace, through: block, now: Self.now)
        }
        // Read down to two days back: every fill of the day-old coin is held.
        let twoDays = Self.head.number - 2 * dayBlocks - LaunchpadService.tradeLookbackMargin
        XCTAssertEqual(coverage(Self.snapshot(coveredFrom: twoDays)), .complete)
        // Read down only to half a day back: still reading, never a part as final.
        XCTAssertEqual(coverage(Self.snapshot(coveredFrom: Self.head.number - dayBlocks / 2)), .reading)
        // Stalled (the rounds stopped short): unread, with Retry.
        XCTAssertEqual(coverage(Self.snapshot(reachedChain: false, coveredFrom: Self.head.number - dayBlocks / 2)), .unread)
        // The head never read: nothing is held in one piece with it.
        XCTAssertEqual(coverage(Self.snapshot(coveredFrom: nil)), .reading)
        // A curve the fills weren't matched to yet.
        XCTAssertEqual(coverage(Self.snapshot(coveredFrom: twoDays, curves: [Self.curveB])), .reading)
        // Last refreshed ten minutes ago: a trade since may be missing, so it waits for the next round; unread if that can't come.
        let stale = Self.now.addingTimeInterval(-600)
        XCTAssertEqual(coverage(Self.snapshot(coveredFrom: twoDays, updated: stale)), .reading)
        XCTAssertEqual(coverage(Self.snapshot(reachedChain: false, coveredFrom: twoDays, updated: stale)), .unread)
        // A coin from the first launchpad needs the whole window: complete once the scan is.
        let first = 1_800_000_000 - 40 * 86_400
        XCTAssertEqual(coverage(Self.snapshot(coveredFrom: twoDays), launchedAt: first), .reading)
        XCTAssertEqual(coverage(Self.snapshot(complete: true, progress: 1, coveredFrom: LaunchpadAddresses.feeHistoryStart), launchedAt: first), .complete)
        // A scan complete to a floor the store raised past the coin's launch (older logs dropped at its cap): unread, never a part.
        XCTAssertEqual(coverage(Self.snapshot(complete: true, progress: 1, coveredFrom: twoDays), launchedAt: first), .unread)
    }

    /// The balance is read live, the fills from the history: a holding's profit and loss is final only once the scan's head
    /// has reached the block the balance was read at. A buy made in the app just before My Launchpad opened, whose fill the
    /// last round didn't read, never shows the new coins' whole value as profit (nor a partial sell as a loss), however
    /// recently the scan was refreshed; once a round reads that block, it is final, however long ago.
    func testProfitAndLossWaitsForTheBlockTheBalanceWasReadAt() {
        let pace = BlockClock.fallbackSecondsPerBlock
        let dayOld = 1_800_000_000 - 86_400
        let twoDays = Self.head.number - 2 * BlockClock.blocks(in: 86_400, secondsPerBlock: pace) - LaunchpadService.tradeLookbackMargin
        func coverage(_ snapshot: WalletHistorySnapshot, through block: UInt64?) -> HistoryCoverage {
            snapshot.fillsCoverage(curve: Self.curveA, launchedAt: dayOld, secondsPerBlock: pace, through: block, now: Self.now)
        }
        let fresh = Self.snapshot(coveredFrom: twoDays)
        XCTAssertEqual(coverage(fresh, through: Self.head.number + 40), .reading, "refreshed a moment ago, but before the balance's block")
        XCTAssertEqual(coverage(fresh, through: Self.head.number), .complete)
        XCTAssertEqual(coverage(fresh, through: Self.head.number - 10), .complete)
        let old = Self.snapshot(coveredFrom: twoDays, updated: Self.now.addingTimeInterval(-3_600))
        XCTAssertEqual(coverage(old, through: Self.head.number), .complete, "read through the balance's block: final, whenever it was read")
        XCTAssertEqual(coverage(old, through: Self.head.number + 1), .reading)
        XCTAssertEqual(coverage(Self.snapshot(complete: true, progress: 1, coveredFrom: LaunchpadAddresses.feeHistoryStart), through: Self.head.number + 1), .reading,
                       "complete, but behind the balance's block: it waits for the round the screen kicks")
        XCTAssertEqual(coverage(Self.snapshot(reachedChain: false, coveredFrom: twoDays), through: Self.head.number + 1), .unread, "the chain unreachable: unread, with Retry")
        XCTAssertEqual(coverage(Self.snapshot(complete: true, progress: 1, reachedChain: false, coveredFrom: LaunchpadAddresses.feeHistoryStart, updated: Self.now.addingTimeInterval(-3_600)),
                                through: Self.head.number + 1), .unread, "complete but behind the balance, and the chain unreachable: unread, with Retry")

        // How far it has got: the blocks since the launch, never 100% until the head reaches the balance's block.
        XCTAssertEqual(fresh.fillsProgress(launchedAt: dayOld, secondsPerBlock: pace, through: Self.head.number, now: Self.now), 1)
        XCTAssertEqual(fresh.fillsProgress(launchedAt: dayOld, secondsPerBlock: pace, through: Self.head.number + 1, now: Self.now), WalletHistorySnapshot.readingCap)
        XCTAssertEqual(old.fillsProgress(launchedAt: dayOld, secondsPerBlock: pace, through: nil, now: Self.now), WalletHistorySnapshot.readingCap, "not read lately")
        let half = Self.snapshot(coveredFrom: Self.head.number - BlockClock.blocks(in: 86_400, secondsPerBlock: pace) / 2)
        XCTAssertLessThan(half.fillsProgress(launchedAt: dayOld, secondsPerBlock: pace, through: Self.head.number, now: Self.now), 0.5)
        XCTAssertEqual(WalletHistorySnapshot.empty.fillsProgress(launchedAt: dayOld, secondsPerBlock: pace, through: nil, now: Self.now), 0)
    }

    /// The launch's block is estimated early (a quarter more age, plus the margin), never before the first launchpad, and
    /// unknown before the history read a head.
    func testTheLaunchBlockIsEstimatedEarly() throws {
        let pace = 0.3
        let snapshot = Self.snapshot(coveredFrom: nil)
        let hourOld = try XCTUnwrap(snapshot.launchBlock(launchedAt: 1_800_000_000 - 3_600, secondsPerBlock: pace))
        XCTAssertEqual(hourOld, Self.head.number - 15_000 - LaunchpadService.tradeLookbackMargin, "12,000 blocks of age, a quarter more, plus the margin")
        XCTAssertLessThan(hourOld, Self.head.number - BlockClock.blocks(in: 3_600, secondsPerBlock: 0.25), "even on a chain a sixth faster than measured")
        XCTAssertEqual(snapshot.launchBlock(launchedAt: 1_000_000_000, secondsPerBlock: pace), LaunchpadAddresses.feeHistoryStart, "never before the first launchpad")
        XCTAssertEqual(snapshot.launchBlock(launchedAt: 1_900_000_000, secondsPerBlock: pace), Self.head.number - LaunchpadService.tradeLookbackMargin, "a clock ahead reads the margin")
        XCTAssertNil(WalletHistorySnapshot.empty.launchBlock(launchedAt: 1_800_000_000, secondsPerBlock: pace))
    }

    /// The Activity tab is the whole window's fills: complete only once the scan is, up to the block the screen's balances
    /// were read at (or, with none, read lately), with the chain reachable; reading while it fills in or a round is due,
    /// unread when it stalled; and it waits for every curve to be matched. A scan read from the device hours ago, after the
    /// wallet's first trade, never says "No launchpad activity".
    func testTheActivityFeedSaysWhenItIsPartial() {
        let complete = Self.snapshot(complete: true, progress: 1, coveredFrom: LaunchpadAddresses.feeHistoryStart)
        XCTAssertEqual(complete.fillsCoverage(curves: [Self.curveA], through: nil, now: Self.now), .complete)
        XCTAssertEqual(complete.fillsCoverage(curves: [Self.curveA], through: Self.head.number, now: Self.now), .complete)
        XCTAssertEqual(complete.fillsCoverage(curves: [Self.curveA], through: Self.head.number + 1, now: Self.now), .reading, "a trade since the head may be missing")
        let onDisk = Self.snapshot(complete: true, progress: 1, coveredFrom: LaunchpadAddresses.feeHistoryStart, updated: Self.now.addingTimeInterval(-4 * 3_600))
        XCTAssertEqual(onDisk.fillsCoverage(curves: [Self.curveA], through: nil, now: Self.now), .reading, "hours old: a round reads it again first")
        XCTAssertEqual(onDisk.fillsCoverage(curves: [Self.curveA], through: Self.head.number, now: Self.now), .complete, "read through the balances' block")
        XCTAssertEqual(Self.snapshot(complete: true, progress: 1, coveredFrom: LaunchpadAddresses.feeHistoryStart, updated: nil).fillsCoverage(curves: [Self.curveA], through: nil, now: Self.now),
                       .reading, "never read at all: not final")
        XCTAssertEqual(Self.snapshot(complete: true, progress: 1, reachedChain: false, coveredFrom: LaunchpadAddresses.feeHistoryStart).fillsCoverage(curves: [Self.curveA], through: nil, now: Self.now),
                       .unread, "the chain unreachable: unread, with Retry, never final")
        XCTAssertEqual(Self.snapshot(coveredFrom: Self.head.number - 1_000).fillsCoverage(curves: [Self.curveA], through: nil, now: Self.now), .reading)
        XCTAssertEqual(Self.snapshot(reachedChain: false, coveredFrom: Self.head.number - 1_000).fillsCoverage(curves: [Self.curveA], through: nil, now: Self.now), .unread)
        XCTAssertEqual(complete.fillsCoverage(curves: [Self.curveA, Self.curveB], through: nil, now: Self.now), .reading)
        XCTAssertEqual(WalletHistorySnapshot.empty.fillsCoverage(curves: [], through: nil), .reading, "nothing read yet")

        // Its progress: the whole window's, short of 100% until the head reaches the balances' block.
        XCTAssertEqual(complete.fillsProgress(through: Self.head.number, now: Self.now), 1)
        XCTAssertEqual(complete.fillsProgress(through: Self.head.number + 1, now: Self.now), WalletHistorySnapshot.readingCap)
        XCTAssertEqual(onDisk.fillsProgress(through: nil, now: Self.now), WalletHistorySnapshot.readingCap)
        XCTAssertEqual(Self.snapshot(progress: 0.35, coveredFrom: Self.head.number - 1_000).fillsProgress(through: nil, now: Self.now), 0.35)
    }

    /// A scan's status says the oldest block read in one piece with its head; a head not read has none.
    func testTheStatusSaysWhatIsReadInOnePieceWithTheHead() {
        var entry = HistoryEntry(covered: [100...200, 300...500], head: 500, floor: 50)
        XCTAssertEqual(HistoryStatus(entry).coveredFrom, 300)
        XCTAssertTrue(HistoryStatus(entry).covers(from: 300))
        XCTAssertFalse(HistoryStatus(entry).covers(from: 250), "a gap below")
        XCTAssertEqual(HistoryStatus(entry).unreached().coveredFrom, 300, "a stalled scan keeps what it read")
        entry.head = 600
        XCTAssertNil(HistoryStatus(entry).coveredFrom, "the head itself unread")
        XCTAssertFalse(HistoryStatus(entry).covers(from: 0))
        XCTAssertNil(HistoryStatus.none.coveredFrom)
    }
}
