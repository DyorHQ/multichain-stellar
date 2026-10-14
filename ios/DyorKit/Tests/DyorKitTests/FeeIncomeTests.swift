import BigInt
import XCTest
@testable import DyorKit

/// What a wallet earned in launchpad fees (`LaunchpadFeeIncome`) and from the Moments it published
/// (`MomentCreatorEarnings`), from the logs that record it. The fixtures are a real creator's (0x90f3…4C47) on Monad
/// mainnet, read 2026-10-08: eleven creator fees the v2 escrow paid straight to the wallet (1,291.315 MON), and on the
/// first launchpad four claims of fees its escrow had booked (4.336 MON) and one of aBIL.
final class FeeIncomeTests: XCTestCase {
    private static let wallet = Address(literal: "0x90f3e7c3B4E32494b06814Fd2F4556671F5F4C47")
    private static let v2Escrow = Address(literal: "0x690eaa0b66C3738887007a0D99ED90b5f5af86F1")
    private static let firstEscrow = Address(literal: "0x1253b18077E8b52FC2522F5B62Ebd2B176383231")
    private static let aBIL = Address(literal: "0x4fc5b9f8933597d3ecf84d0611687e1dc8dd576f")

    private static func word(_ address: Address) -> Data { address.data.leftPadded(to: 32) }
    private static func amount(_ value: BigUInt) -> Data { value.serialize().leftPadded(to: 32) }
    private static func hash(_ n: Int) -> Data { Data([UInt8(n & 0xff), UInt8(n >> 8)]).leftPadded(to: 32) }

    private static func escrowLog(_ topic: Data, token: Address? = nil, value: BigUInt, escrow: Address = v2Escrow, block: UInt64, index: Int) -> Log {
        Log(address: escrow, topics: [topic, word(wallet)] + (token.map { [word($0)] } ?? []), data: amount(value), blockNumber: block, transactionHash: hash(Int(block % 60_000)), logIndex: index)
    }

    /// The v2 escrow's `Paid` logs for the wallet: (block, log index, wei).
    private static let paid: [(UInt64, Int, BigUInt)] = [
        (110_814_481, 129, BigUInt("715000000000000000")), (110_815_150, 137, BigUInt("55000000000000000000")),
        (110_815_192, 74, BigUInt("440000000000000000000")), (110_815_225, 134, BigUInt("165000000000000000000")),
        (110_881_218, 46, BigUInt("620399999999999999999")), (111_340_939, 130, BigUInt("2750000000000000000")),
        (111_341_083, 86, BigUInt("550000000000000000")), (111_341_117, 234, BigUInt("550000000000000000")),
        (111_344_668, 166, BigUInt("5250000000000000000")), (111_362_679, 61, BigUInt("550000000000000000")),
        (111_369_561, 99, BigUInt("550000000000000000")),
    ]
    /// The first escrow's logs for the wallet: booked (`Credited`), then claimed.
    private static var firstEscrowLogs: [Log] {
        let e = LaunchpadABI.Events.self
        let credited = ABI.eventTopic("Credited(address,uint256)"), creditedToken = ABI.eventTopic("CreditedToken(address,address,uint256)")
        return [
            escrowLog(credited, value: BigUInt("100000000000000000"), escrow: firstEscrow, block: 103_613_874, index: 3),
            escrowLog(credited, value: BigUInt("6000553211485913"), escrow: firstEscrow, block: 103_614_743, index: 283),
            escrowLog(e.escrowClaimedTopic, value: BigUInt("106000553211485913"), escrow: firstEscrow, block: 103_655_091, index: 24),
            escrowLog(credited, value: BigUInt("500000000000000000"), escrow: firstEscrow, block: 103_676_420, index: 26),
            escrowLog(e.escrowClaimedTopic, value: BigUInt("500000000000000000"), escrow: firstEscrow, block: 103_744_749, index: 19),
            escrowLog(creditedToken, token: aBIL, value: BigUInt("15000000000000"), escrow: firstEscrow, block: 103_746_145, index: 11),
            escrowLog(creditedToken, token: aBIL, value: BigUInt("14699999999999"), escrow: firstEscrow, block: 103_746_506, index: 47),
            escrowLog(e.escrowClaimedTopic, value: BigUInt("230706318613022330"), escrow: firstEscrow, block: 103_746_819, index: 48),
            escrowLog(e.escrowClaimedTokenTopic, token: aBIL, value: BigUInt("29699999999999"), escrow: firstEscrow, block: 103_746_825, index: 87),
            escrowLog(e.escrowClaimedTopic, value: BigUInt("3499702407943663193"), escrow: firstEscrow, block: 103_951_869, index: 1),
        ]
    }

    /// Fees paid straight to the wallet and fees it claimed are both received; what was only booked (`Credited`) is not.
    func testTheCreatorsFeesReceived() {
        let paidLogs = Self.paid.map { Self.escrowLog(LaunchpadABI.Events.escrowPaidTopic, value: $0.2, block: $0.0, index: $0.1) }
        let income = LaunchpadService.feeIncome(escrowLogs: paidLogs + Self.firstEscrowLogs, sharingLogs: [])
        XCTAssertEqual(income.paid[.zero], BigUInt("1291314999999999999999"), "the eleven payments, to the wei")
        XCTAssertEqual(income.claimed[.zero], BigUInt("4336409279768171436"), "four claims of booked fees")
        XCTAssertEqual(income.claimed[Self.aBIL], BigUInt("29699999999999"))
        XCTAssertNil(income.paid[Self.aBIL])
        XCTAssertEqual(income.creatorFeesReceived[.zero], BigUInt("1295651409279768171435"), "1,295.65 MON received")
        XCTAssertEqual(income.creatorFeesReceived[Self.aBIL], BigUInt("29699999999999"))
        XCTAssertEqual(income.rewardsClaimed, [:])
        XCTAssertEqual(NumberStyle.units(income.creatorFeesReceived[.zero]!, decimals: 18), "1,295.65")
    }

    /// A log read twice (two scans that overlap) counts once; a log of another shape, or a claim of holder rewards, is
    /// read for what it is.
    func testEachLogCountsOnce() {
        let e = LaunchpadABI.Events.self
        let paid = Self.escrowLog(e.escrowPaidTopic, value: 5, block: 1, index: 0)
        let paidToken = Self.escrowLog(e.escrowPaidTokenTopic, token: Monad.usdc, value: 7, block: 2, index: 0)
        let malformed = Log(address: Self.v2Escrow, topics: [e.escrowPaidTopic], data: Self.amount(9), blockNumber: 3, transactionHash: Self.hash(3), logIndex: 0)
        let coin = Address(literal: "0x00000000000000000000000000000000000c0110")
        let reward = Log(address: Address(literal: "0x5358a136a50eE4F961B532064dc641E8F4Fa5656"), topics: [e.sharingClaimedTopic, Self.word(coin), Self.word(Self.wallet)],
                         data: Self.amount(11), blockNumber: 4, transactionHash: Self.hash(4), logIndex: 0)
        let income = LaunchpadService.feeIncome(escrowLogs: [paid, paid, paidToken, malformed], sharingLogs: [reward, reward])
        XCTAssertEqual(income.paid, [.zero: 5, Monad.usdc: 7])
        XCTAssertEqual(income.claimed, [:])
        XCTAssertEqual(income.rewardsClaimed, [coin: 11])
    }

    /// The Portfolio's history reads the same payments, newest first.
    func testTheWalletHistoryReadsThePayments() {
        let e = LaunchpadABI.Events.self
        let anchor = BlockHeader(number: 111_400_000, timestamp: 1_791_400_000)
        let paid = Self.paid.map { Self.escrowLog(e.escrowPaidTopic, value: $0.2, block: $0.0, index: $0.1) }
        let paidToken = [Self.escrowLog(e.escrowPaidTokenTopic, token: Monad.usdc, value: 3, block: 111_000_000, index: 5)]
        let history = LaunchpadService.walletHistory(buys: [], sells: [], escrowNative: [], escrowToken: [], sharing: [], paid: paid, paidToken: paidToken,
                                                     anchor: anchor, secondsPerBlock: 0.4, curves: [])
        XCTAssertEqual(history.payments.count, 12)
        XCTAssertEqual(history.payments.first?.block, 111_369_561, "newest first")
        XCTAssertEqual(history.payments.filter { $0.token.isZero }.reduce(BigUInt(0)) { $0 + $1.amount }, BigUInt("1291314999999999999999"))
        XCTAssertEqual(history.payments.first { !$0.token.isZero }?.token, Monad.usdc)
    }

    /// From v1 the escrow pays each fee straight to its recipient; the first two launchpads' escrows only book fees to
    /// claim (their code has no `Paid` event, read 2026-10-08). The coin page and My Launchpad describe fees by this.
    func testEscrowsFromV1PayFeesStraightToTheRecipient() {
        let stacks = [LaunchpadAddresses.monadMainnet] + LaunchpadAddresses.retiredStacks
        XCTAssertEqual(stacks.map(\.escrow), [Self.v2Escrow, Address(literal: "0x5EDA8765934fE22fa63d671465eF914Cd196968e"),
                                              Address(literal: "0xbc70ba9D66F761FFb7647D6B52C8Cf65a49E47fc"),
                                              Address(literal: "0xeDC73b06BE454714b6Bd0C1c742e51e605664B2A"), Self.firstEscrow])
        XCTAssertEqual(stacks.map(\.generation.pushesFees), [true, true, true, false, false])
        XCTAssertEqual(LaunchpadAddresses.Generation.allCases.filter(\.pushesFees), [.v1, .v2])
    }

    // MARK: Moments

    private static let v2Factory = Address(literal: "0x95eb7F5A88B10D9dF32aC54F48C767927fa80840")
    private static let v2Collect = Address(literal: "0xe6beb4A10827a2e50B155B7386b1369d504186Cc")
    private static let v2Hook = Address(literal: "0xDa7042CF42B26Be4d6816C9eeB1B0bee8e3Fe0cc")

    private static func published(id: BigUInt, creator: Address, factory: Address = v2Factory, index: Int) -> Log {
        let data = try! ABI.encode([.address(.zero), .address(.zero), .uint(100_000), .uint(500), .uint(1), .uint(1), .uint(0)], "address,address,uint256,uint16,uint256,uint256,uint64")
        return Log(address: factory, topics: [MomentsABI.Events.publishedTopic, id.serialize().leftPadded(to: 32), word(creator)], data: data, blockNumber: 109_000_000,
                   transactionHash: hash(index), logIndex: index)
    }

    /// The Moments a wallet published come from its `Published` logs on the cohort's own factory, each once.
    func testCreatedMomentsComeFromThePublishes() {
        let stranger = Address(literal: "0x00000000000000000000000000000000000057a6")
        let logs = [Self.published(id: 2, creator: Self.wallet, index: 1), Self.published(id: 1, creator: Self.wallet, index: 2),
                    Self.published(id: 1, creator: Self.wallet, index: 2), Self.published(id: 3, creator: stranger, index: 3),
                    Self.published(id: 4, creator: Self.wallet, factory: Self.v2Collect, index: 4)]
        XCTAssertEqual(MomentsService.createdIds(logs, account: Self.wallet, factory: Self.v2Factory), [1, 2])
    }

    /// The wallet's v2 Moments, read 2026-10-08: WAGMI (#1) holds 0.04 USDC of its collects, Monad Open (#2) had its
    /// 0.12 withdrawn (neither has graduated: WAGMI's pool fees here are made up, for the hook's half). A withdrawal of
    /// another Moment, or naming another beneficiary, is not the creator's.
    func testAMomentsProceedsAreClaimedPlusUnclaimed() {
        func withdrawal(_ topic: Data, emitter: Address, id: BigUInt, to: Address = FeeIncomeTests.wallet, amount value: BigUInt, index: Int) -> Log {
            Log(address: emitter, topics: [topic, id.serialize().leftPadded(to: 32), Self.word(to)], data: Self.amount(value), blockNumber: 110_000_000,
                transactionHash: Self.hash(100 + index), logIndex: index)
        }
        let platform = Address(literal: "0x000000000000000000000000000000000000F00D")
        let withdrawn = [withdrawal(MomentsABI.Events.withdrawnTopic, emitter: Self.v2Collect, id: 2, amount: 120_000, index: 1),
                         withdrawal(MomentsABI.Events.withdrawnTopic, emitter: Self.v2Collect, id: 2, amount: 120_000, index: 1),
                         withdrawal(MomentsABI.Events.withdrawnTopic, emitter: Self.v2Collect, id: 9, amount: 5_000, index: 2),
                         withdrawal(MomentsABI.Events.withdrawnTopic, emitter: Self.v2Collect, id: 1, to: platform, amount: 7_000, index: 3)]
        let fees = [withdrawal(MomentsABI.Events.feesWithdrawnTopic, emitter: Self.v2Hook, id: 1, amount: 2_500, index: 4)]
        let earnings = MomentsService.creatorEarnings(held: [(id: 1, proceeds: 40_000, fees: 500), (id: 2, proceeds: 0, fees: 0)], withdrawn: withdrawn,
                                                      feesWithdrawn: fees, account: Self.wallet, factory: Self.v2Factory)
        XCTAssertEqual(earnings.map(\.key), [MomentKey(factory: Self.v2Factory, id: 1), MomentKey(factory: Self.v2Factory, id: 2)])
        let wagmi = earnings[0], open = earnings[1]
        XCTAssertEqual([wagmi.proceedsWithdrawn, wagmi.proceedsUnclaimed, wagmi.feesWithdrawn, wagmi.feesUnclaimed], [0, 40_000, 2_500, 500])
        XCTAssertEqual([open.proceedsWithdrawn, open.proceedsUnclaimed], [120_000, 0], "read once")
        let all = MomentsCreatorEarnings(moments: earnings, complete: true)
        XCTAssertEqual([all.fromCollectors, all.tradingFees, all.claimed, all.unclaimed], [160_000, 3_000, 122_500, 40_500])
        XCTAssertEqual(all.fromCollectors + all.tradingFees, all.claimed + all.unclaimed, "everything credited is claimed or unclaimed")
        let past = MomentsCreatorEarnings(moments: [MomentCreatorEarnings(key: MomentKey(factory: Self.v2Collect, id: 1), proceedsWithdrawn: 0, proceedsUnclaimed: 20_000,
                                                                          feesWithdrawn: 0, feesUnclaimed: 0)], complete: false)
        let both = all + past
        XCTAssertEqual(both.unclaimed, 60_500)
        XCTAssertFalse(both.complete, "complete only when every cohort is")
    }
}
