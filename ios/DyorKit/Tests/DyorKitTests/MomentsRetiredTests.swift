import BigInt
import XCTest
@testable import DyorKit

/// The retired Moments cohorts: the address table pinned to the deployment records (and the factory getters read on
/// chain), (factory, id) keys that keep equal Moment ids of different cohorts apart, and the claim-only write surface —
/// a retired Moment can only ever produce a vesting claim or a creator withdrawal against its own cohort's contracts.
final class MomentsRetiredTests: XCTestCase {
    private let cohort3 = MomentsAddresses.retiredMainnet[0]
    private let cohort2 = MomentsAddresses.retiredMainnet[1]
    private let cohort1 = MomentsAddresses.retiredMainnet[2]
    /// The live (v2) cohort. Pending (all zero) until the owner deploys; `V2Fixture.moments` stands in where a test needs
    /// a deployed one.
    private let live = MomentsAddresses.monadMainnet
    private let retiredPlatform = Address(literal: "0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48")
    private let retiredTreasury = Address(literal: "0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045")
    private let feesWallet = Address(literal: "0x15ED3bb488231213b141A2f78b62358D52235Cd7")
    private let treasury = Address(literal: "0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371")

    // MARK: Table (moments-143-cohort3.json, moments-143-cohort2.json, moments-143-cohort1.json)

    func testRetiredTableIsPinned() {
        XCTAssertEqual(MomentsAddresses.retiredMainnet.count, 3)

        XCTAssertEqual(cohort3.factory, Address(literal: "0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26"))
        XCTAssertEqual(cohort3.collect, Address(literal: "0xb53897A4C6280480c267351518D184C2E6591D30"))
        XCTAssertEqual(cohort3.vesting, Address(literal: "0x05584910ab57d65723eB878D295b3353a4cbb021"))
        XCTAssertEqual(cohort3.graduation, Address(literal: "0xA2231E39ce7AE4f7d5e56Beae2dD3a8a59F3b9aA"))
        XCTAssertEqual(cohort3.locker, Address(literal: "0x37C5A2c15d99701CF698B146cdCD1853825Ef455"))
        XCTAssertEqual(cohort3.hook, Address(literal: "0xD5BFff467FDAe04664357e75bF059986c41260CC"))
        XCTAssertEqual(cohort3.buyback, Address(literal: "0x3B574312Bb4e1D36C9a1Ba698bf77BbD223ca913"))
        XCTAssertEqual(cohort3.deployBlock, 107_311_600)

        XCTAssertEqual(cohort2.factory, Address(literal: "0xc12B6b6948185cef75F861c5327702c30CB8a581"))
        XCTAssertEqual(cohort2.collect, Address(literal: "0x8f65ea0236b5fa6351a45Bd48244c3525Fb92493"))
        XCTAssertEqual(cohort2.vesting, Address(literal: "0xe087eff01C567F88a7cb6BDBDBF04B46Fee56C99"))
        XCTAssertEqual(cohort2.graduation, Address(literal: "0x353F245A2458B994a65116A4c69643cf6608045b"))
        XCTAssertEqual(cohort2.locker, Address(literal: "0x995735cF317656a10de52b73AB50A2aAdc069a8a"))
        XCTAssertEqual(cohort2.hook, Address(literal: "0x501D703588c4feAbBeE5A9a77408c7FCbD3a20Cc"))
        XCTAssertEqual(cohort2.buyback, Address(literal: "0xacae95377513C54DA9ff549DFE5cB77001F6c6F5"))
        XCTAssertEqual(cohort2.deployBlock, 106_984_957)

        XCTAssertEqual(cohort1.factory, Address(literal: "0x64698c7702d85F87f43a6dFF7D495CDD2327C020"))
        XCTAssertEqual(cohort1.collect, Address(literal: "0xb4EE9e67d9e1772BC6949748e3755EA7C1DFE32c"))
        XCTAssertEqual(cohort1.vesting, Address(literal: "0x360E2068eAEc5b5A9AF60A7c4059Bd4b30B7209C"))
        XCTAssertEqual(cohort1.graduation, Address(literal: "0x307De00950F039969855eFb859A6088d695e76b1"))
        XCTAssertEqual(cohort1.locker, Address(literal: "0x832851A42Bf1FD1aF7a19c82cF132290c605E406"))
        XCTAssertEqual(cohort1.hook, Address(literal: "0x8Aa322471Bef2996D3B50cB12F63C6A0054460Cc"))
        XCTAssertEqual(cohort1.buyback, Address(literal: "0x03282D5421a3bE3ff79c5962819c9a6e5E0b52d2"))
        XCTAssertEqual(cohort1.deployBlock, 105_347_754)

        for cohort in MomentsAddresses.retiredMainnet {
            XCTAssertTrue(cohort.isDeployed)
            // Every retired cohort runs the v1 source: no v2 getter is ever sent to one.
            XCTAssertEqual(cohort.generation, .v1)
            // The shared infrastructure is the live one's.
            XCTAssertEqual(cohort.usdc, live.usdc)
            XCTAssertEqual(cohort.permit2, live.permit2)
            XCTAssertEqual(cohort.poolManager, live.poolManager)
            XCTAssertNotEqual(cohort.factory, live.factory)
            XCTAssertEqual(MomentsAddresses.retired(factory: cohort.factory), cohort)
        }
        // Beneficiaries, per cohort: 1 and 2 snapshotted the retired wallets, 3 the current ones, and each says why it
        // is retired.
        for cohort in [cohort1, cohort2] {
            XCTAssertEqual(cohort.platform, retiredPlatform)
            XCTAssertEqual(cohort.treasury, retiredTreasury)
            XCTAssertEqual(cohort.retirement, .retiredWallets)
        }
        XCTAssertEqual(cohort3.platform, feesWallet)
        XCTAssertEqual(cohort3.treasury, treasury)
        XCTAssertEqual(cohort3.retirement, .replaced)
        // Newest first, by deployment block (independent of the pending v2 table); the live cohort is not retired.
        XCTAssertGreaterThan(cohort3.deployBlock, cohort2.deployBlock)
        XCTAssertGreaterThan(cohort2.deployBlock, cohort1.deployBlock)
        XCTAssertEqual(live.generation, .v2)
        XCTAssertNil(live.retirement)
        if live.isDeployed { XCTAssertNil(MomentsAddresses.retired(factory: live.factory)) }
        XCTAssertNil(MomentsAddresses.retired(factory: .zero), "the pending v2 table is never a retired cohort")
        XCTAssertNil(MomentsAddresses.retired(factory: V2Fixture.moments.factory))
        // No contract is shared between cohorts (the v2 fixture stands in for the pending table).
        let contracts = ([V2Fixture.moments] + MomentsAddresses.retiredMainnet).flatMap { [$0.factory, $0.collect, $0.vesting, $0.graduation, $0.locker, $0.hook, $0.buyback] }
        XCTAssertEqual(Set(contracts).count, contracts.count)
        XCTAssertFalse(contracts.contains(.zero))
    }

    /// The retired coins, pinned (read on chain with getMoment / momentIdByCoin): the app refuses to trade these even
    /// when their cohort cannot be read.
    func testRetiredCoinsArePinned() {
        let coins = MomentsAddresses.retiredMainnetCoins
        XCTAssertEqual(coins.count, 6)
        XCTAssertEqual(coins[Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF")], MomentKey(factory: cohort3.factory, id: 1), "Nature")
        XCTAssertEqual(coins[Address(literal: "0xC18941ca9fBaa613841c3d31a7Dd1D262a47a2E5")], MomentKey(factory: cohort2.factory, id: 1))
        XCTAssertEqual(coins[Address(literal: "0x01D2c48E3cd38804a643E391421289933ed3D4a7")], MomentKey(factory: cohort2.factory, id: 2))
        XCTAssertEqual(coins[Address(literal: "0xDc1bC41b7C197DE19f17C7832bec3Bb748D92297")], MomentKey(factory: cohort1.factory, id: 1))
        XCTAssertEqual(coins[Address(literal: "0xd6c17E083b53fa1c46b71120D6959303Ae4B8e1F")], MomentKey(factory: cohort1.factory, id: 2))
        XCTAssertEqual(coins[Address(literal: "0x8D2AEc229b5A4Fd4D4aB1725c92B6B7f53fBc50f")], MomentKey(factory: cohort1.factory, id: 3))
        // Every Moment of the three cohorts (each at its pinned final count), each exactly once.
        XCTAssertEqual(Set(coins.values), Set([MomentKey(factory: cohort3.factory, id: 1)] + [1, 2].map { MomentKey(factory: cohort2.factory, id: $0) }
                                              + [1, 2, 3].map { MomentKey(factory: cohort1.factory, id: $0) }))
        XCTAssertEqual(MomentLink.Cohort.allCases.compactMap(\.finalMomentCount).reduce(0, +), coins.count, "one coin per pinned Moment")
        for coin in coins.keys { XCTAssertTrue(MomentsAddresses.isRetiredCoin(coin)) }
        for token in [live.usdc, Monad.wmon, Address.zero, V2Fixture.moments.factory] { XCTAssertFalse(MomentsAddresses.isRetiredCoin(token)) }
    }

    // MARK: (factory, id) keys

    private func info(id: BigUInt, factory: Address, creator: Address = .zero, state: MomentState = .collecting, graduated: Bool = false,
                      creatorClaimable: BigUInt = 0, creatorFees: BigUInt = 0) -> MomentInfo {
        let byte = UInt8(truncatingIfNeeded: factory.data.last ?? 0)
        let m = Moment(id: id, creator: creator, platform: retiredPlatform, treasury: retiredTreasury,
                       coin: Address(data: Data(repeating: byte, count: 19) + Data([UInt8(truncatingIfNeeded: Int(id))]))!, nft: Address(data: Data(repeating: byte &+ 1, count: 19) + Data([UInt8(truncatingIfNeeded: Int(id))]))!,
                       price: 100_000, threshold: 10_000_000, rateNum: 1, rateDen: 1, creatorBps: 2_000, platformBps: 500, reserveBps: 7_500,
                       creatorAllocBps: 1_000, expiryCreatorBps: 7_000, royaltyBps: 500, publishedAt: 1_000, deadline: 2_000, factory: factory)
        let ledger = MomentLedger(state: state, completedAt: 0, stuckSince: 0, endedAt: 0, reserve: 0, creatorClaimable: creatorClaimable, platformClaimable: 5_000,
                                  treasuryClaimable: 7_000, totalGross: 100_000, collects: 1)
        let pool = graduated ? MomentPool(key: PoolKey(currency0: live.usdc, currency1: m.coin, fee: 5_000, tickSpacing: 60), poolId: Data(repeating: 1, count: 32), usdcIs0: true,
                                          sqrtPriceX96: 1, openingSqrtPriceX96: 1, liquidity: 1, seedLiquidity: 1, reserveSeed: 1, poolCoins: 1, graduatedAt: 1_500, usdcPerCoin: 0,
                                          creatorFees: creatorFees, platformFees: 3_000, buybackFees: 0, buybackCarry: 0, lastBuyback: 0, buybackInterval: 0, buybackMin: 0) : nil
        return MomentInfo(moment: m, name: "M\(id)", symbol: "M\(id)", provenance: MomentProvenance(mediaURI: "", mediaHash: Data(), place: "", date: 0, animationURI: ""),
                          ledger: ledger, editions: 1, closed: false, entitlements: 0, graduated: graduated, progressBps: 0, pool: pool)
    }

    func testEqualIdsOnDifferentCohortsNeverCollide() {
        let live = V2Fixture.moments
        let a = info(id: 1, factory: live.factory)
        let b = info(id: 1, factory: cohort2.factory)
        let c = info(id: 1, factory: cohort1.factory)
        XCTAssertEqual(Set([a.id, b.id, c.id]).count, 1)
        XCTAssertEqual(Set([a.key, b.key, c.key]).count, 3)
        let byKey = Dictionary(uniqueKeysWithValues: [a, b, c].map { ($0.key, $0) })
        XCTAssertEqual(byKey.count, 3)
        XCTAssertEqual(byKey[MomentKey(factory: cohort1.factory, id: 1)]?.moment.coin, c.moment.coin)
        XCTAssertNotEqual(MomentKey(factory: cohort2.factory, id: 1).description, MomentKey(factory: cohort1.factory, id: 1).description)

        // History from two cohorts, same Moment id, same transaction hash: the records stay apart and each finds its own Moment.
        let hash = Data(repeating: 0xcc, count: 32)
        let history = MomentsAccountHistory.merged([
            MomentsAccountHistory(collects: [], claims: [MomentClaimRecord(hash: hash, block: 10, time: .now, momentId: 1, collectorAmount: 1, creatorAmount: 0, factory: live.factory)], withdrawals: [], publishes: []),
            MomentsAccountHistory(collects: [], claims: [MomentClaimRecord(hash: hash, block: 20, time: .now, momentId: 1, collectorAmount: 2, creatorAmount: 0, factory: cohort1.factory)], withdrawals: [], publishes: []),
        ])
        XCTAssertEqual(history.claims.count, 2)
        XCTAssertEqual(history.claims.map(\.block), [20, 10]) // newest first
        XCTAssertEqual(Set(history.claims.map(\.id)).count, 2)
        XCTAssertEqual(byKey[history.claims[0].key]?.moment.factory, cohort1.factory)
        XCTAssertEqual(byKey[history.claims[1].key]?.moment.factory, live.factory)

        // The history parser tags every record with the cohort it scanned.
        let wallet = Address(literal: "0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8")
        let claimed = Log(address: cohort1.vesting, topics: [MomentsABI.Events.claimedTopic, BigUInt(1).word, wallet.data.leftPadded(to: 32)],
                          data: Data(hex: "0x00000000000000000000000000000000000000000003599ef09f245bff400000000000000000000000000000000000000000000000108b2a2c28029094000000")!,
                          blockNumber: 105_400_000, transactionHash: hash, logIndex: 0)
        let parsed = MomentsService.history(collected: [], claimed: [claimed], withdrawn: [], feesWithdrawn: [], published: [], anchor: BlockHeader(number: 105_400_100, timestamp: 1_758_000_000),
                                            secondsPerBlock: BlockClockFixture.secondsPerBlock, factory: cohort1.factory)
        XCTAssertEqual(parsed.claims.first?.key, MomentKey(factory: cohort1.factory, id: 1))
    }

    /// The live service refuses another cohort's Moment before reading anything: its id names a different Moment there.
    func testLiveServiceRefusesAnotherCohortsMoment() async throws {
        let service = MomentsService(rpc: RPCClient(url: URL(string: "http://127.0.0.1:1")!), addresses: V2Fixture.moments)
        let retired = info(id: 1, factory: cohort1.factory)
        do {
            _ = try await service.accountView(retired, account: Address(literal: "0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8"))
            XCTFail("a retired Moment was read under the live cohort")
        } catch let error as MomentsService.MomentsError {
            XCTAssertEqual(error, .unknownMoment)
        }
        let portfolio = try await service.portfolio(account: Address(literal: "0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8"), moments: [retired, info(id: 2, factory: cohort2.factory)])
        XCTAssertTrue(portfolio.rows.isEmpty)
    }

    func testPositionsKeyByFactoryAndKeepOnlyWhatIsOpen() {
        let wallet = Address(literal: "0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8")
        let vesting = info(id: 2, factory: cohort1.factory, state: .graduated, graduated: true)
        let sameIdOtherCohort = info(id: 2, factory: cohort2.factory)
        let expiredOnlyPromise = info(id: 1, factory: cohort1.factory, state: .expired)
        let createdOnly = info(id: 1, factory: cohort2.factory, creator: wallet, creatorClaimable: 20_000)
        let rows = [
            MomentPortfolioRow(moment: vesting, entitlement: 100, claimed: 60, claimableCollector: 0, claimableCreator: 0, nftBalance: 0, coinBalance: 0, isCreator: false),
            MomentPortfolioRow(moment: sameIdOtherCohort, entitlement: 50, claimed: 0, claimableCollector: 0, claimableCreator: 0, nftBalance: 1, coinBalance: 0, isCreator: false),
            MomentPortfolioRow(moment: expiredOnlyPromise, entitlement: 50, claimed: 0, claimableCollector: 0, claimableCreator: 0, nftBalance: 0, coinBalance: 0, isCreator: false),
        ]
        let positions = RetiredMoments.positions(rows: rows, moments: [vesting, sameIdOtherCohort, expiredOnlyPromise, createdOnly], account: wallet)
        XCTAssertEqual(positions.map(\.key), [vesting.key, sameIdOtherCohort.key, createdOnly.key])
        XCTAssertEqual(Set(positions.map(\.id)).count, positions.count)
        // Same id on two cohorts: each position carries its own row, not the other cohort's.
        XCTAssertEqual(positions[0].row.entitlement, 100)
        XCTAssertEqual(positions[1].row.entitlement, 50)
        // The creator-only Moment gets a row for its proceeds.
        XCTAssertEqual(positions[2].creatorProceeds, 20_000)
        XCTAssertTrue(positions[2].row.isCreator)
        // Someone else's Moment never shows the creator's money.
        XCTAssertEqual(positions[1].creatorWithdrawable, 0)
    }

    /// A retired Moment still collecting past its deadline (cohort 3's "Nature" once its window closes, until someone
    /// expires it outside the app) has missed graduation: a promise of coins alone no longer keeps it open, while
    /// editions and creator proceeds still do.
    func testAMomentPastItsDeadlineHasMissedGraduation() {
        let wallet = Address(literal: "0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8")
        let collecting = info(id: 1, factory: cohort3.factory) // deadline 2_000
        XCTAssertFalse(collecting.missedGraduation(at: 1_999))
        XCTAssertTrue(collecting.missedGraduation(at: 2_000))
        XCTAssertTrue(info(id: 1, factory: cohort3.factory, state: .expired).missedGraduation(at: 1_000))
        XCTAssertFalse(info(id: 1, factory: cohort3.factory, state: .graduationPending).missedGraduation(at: 9_999), "a stuck graduation may still be retried")
        XCTAssertFalse(info(id: 1, factory: cohort3.factory, state: .graduated, graduated: true).missedGraduation(at: 9_999))

        let promise = MomentPortfolioRow(moment: collecting, entitlement: 50, claimed: 0, claimableCollector: 0, claimableCreator: 0, nftBalance: 0, coinBalance: 0, isCreator: false)
        XCTAssertEqual(RetiredMoments.positions(rows: [promise], moments: [collecting], account: wallet, now: 1_999).map(\.key), [collecting.key])
        XCTAssertEqual(RetiredMoments.positions(rows: [promise], moments: [collecting], account: wallet, now: 2_000).map(\.key), [])
        let edition = MomentPortfolioRow(moment: collecting, entitlement: 50, claimed: 0, claimableCollector: 0, claimableCreator: 0, nftBalance: 1, coinBalance: 0, isCreator: false)
        XCTAssertEqual(RetiredMoments.positions(rows: [edition], moments: [collecting], account: wallet, now: 2_000).map(\.key), [collecting.key], "editions stay theirs")
        let created = info(id: 1, factory: cohort3.factory, creator: wallet, creatorClaimable: 20_000)
        XCTAssertEqual(RetiredMoments.positions(rows: [], moments: [created], account: wallet, now: 2_000).first?.creatorProceeds, 20_000)
    }

    // MARK: Live (read-only; DYOR_LIVE_MOMENTS=1)

    /// The retired cohorts read from Monad mainnet through the claim-only client, at their pinned final counts; every
    /// Moment carries its own factory and its cohort's beneficiaries (the retired wallets on 1 and 2, the current ones
    /// on 3).
    func testLiveRetiredCohortsReadThroughTheirOwnContracts() async throws {
        guard ProcessInfo.processInfo.environment["DYOR_LIVE_MOMENTS"] == "1" else { throw XCTSkip("set DYOR_LIVE_MOMENTS=1") }
        let rpc = RPCClient(url: URL(string: "https://rpc1.monad.xyz")!)
        var keys: Set<MomentKey> = []
        XCTAssertEqual(MomentLink.Cohort.allCases.compactMap(\.finalMomentCount), [3, 2, 1])
        for (cohort, count) in zip(MomentsAddresses.retiredMainnet, [1, 2, 3]) {
            let client = RetiredMoments(rpc: rpc, addresses: cohort)
            let moments: [MomentInfo]
            do { moments = try await client.moments() } catch { throw XCTSkip("Monad RPC unreachable: \(error)") }
            XCTAssertEqual(moments.count, count)
            for info in moments {
                XCTAssertEqual(info.moment.factory, cohort.factory)
                XCTAssertEqual(info.moment.platform, cohort.platform)
                XCTAssertEqual(info.moment.treasury, cohort.treasury)
                keys.insert(info.key)
            }
            // The pinned coin table is exact for this cohort.
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: moments.map { ($0.moment.coin, $0.key) }), MomentsAddresses.retiredMainnetCoins.filter { $0.value.factory == cohort.factory })
            if cohort == cohort1 { XCTAssertTrue(moments.first { $0.id == 2 }?.graduated ?? false, "cohort-1 #2 graduated") }
            // The creator of each cohort's first Moment: a history scan from the cohort's deployment block.
            let creator = cohort == cohort3 ? Address(literal: "0x90f3e7c3B4E32494b06814Fd2F4556671F5F4C47") : Address(literal: "0x6115cAF237026B45B037191B20056d1e4AfAfFa3")
            let (history, _) = await client.history(account: creator)
            XCTAssertTrue(history.publishes.allSatisfy { $0.factory == cohort.factory && $0.block >= cohort.deployBlock })
            XCTAssertFalse(history.publishes.isEmpty)
        }
        XCTAssertEqual(keys.count, 6)
    }

    // MARK: Claim-only plans

    func testRetiredPlansOnlyClaimOrWithdrawToTheCreator() {
        // Adding an action is a decision: it must be reviewed against "never pays the retired wallets".
        XCTAssertEqual(RetiredMomentAction.allCases, [.claim, .withdrawCreatorProceeds, .withdrawCreatorFees])
        let claim = ABI.selector(MomentsABI.Vesting.claim)
        let withdrawCreator = ABI.selector(MomentsABI.Collect.withdrawCreator)
        XCTAssertEqual(claim.hexString, "0x379607f5")
        XCTAssertEqual(withdrawCreator.hexString, "0x938a1499")
        XCTAssertEqual(ABI.selector(MomentsABI.Hook.withdrawCreator), withdrawCreator)
        let forbidden = [MomentsABI.Collect.collect, MomentsABI.Collect.collectWithPermit2, MomentsABI.Collect.expire, MomentsABI.Collect.withdrawPlatform,
                         MomentsABI.Collect.withdrawTreasury, MomentsABI.Hook.withdrawPlatform, MomentsABI.Graduation.graduate, MomentsABI.Buyback.execute,
                         MomentsABI.Vesting.claimAll, MomentsABI.Factory.publish].map { ABI.selector($0) }
        let live = V2Fixture.moments
        let liveContracts: Set<Address> = [live.factory, live.collect, live.vesting, live.graduation, live.locker, live.hook, live.buyback]

        for (index, cohort) in MomentsAddresses.retiredMainnet.enumerated() {
            let service = RetiredMoments(rpc: RPCClient(url: URL(string: "http://127.0.0.1:1")!), addresses: cohort)
            let others = MomentsAddresses.retiredMainnet.enumerated().filter { $0.offset != index }.map(\.element)
            for id in [BigUInt(1), 2, 3] {
                for action in RetiredMomentAction.allCases {
                    let steps = service.plan(action, momentId: id, symbol: "M")
                    XCTAssertEqual(steps, RetiredMoments.plan(action, momentId: id, symbol: "M", addresses: cohort))
                    XCTAssertEqual(steps.count, 1, "\(action)")
                    guard let step = steps.first, let request = step.request else { return XCTFail("\(action) built no call") }
                    XCTAssertEqual(step.kind, .call, "\(action) must not approve anything")
                    XCTAssertEqual(request.value, 0)
                    let (to, selector): (Address, Data) = switch action {
                    case .claim: (cohort.vesting, claim)
                    case .withdrawCreatorProceeds: (cohort.collect, withdrawCreator)
                    case .withdrawCreatorFees: (cohort.hook, withdrawCreator)
                    }
                    XCTAssertEqual(request.to, to, "\(action)")
                    XCTAssertEqual(request.data, selector + id.word, "\(action)")
                    XCTAssertFalse(forbidden.contains(request.data.prefix(4)), "\(action)")
                    XCTAssertFalse(liveContracts.contains(request.to))
                    XCTAssertFalse(others.flatMap { [$0.vesting, $0.collect, $0.hook] }.contains(request.to))
                    XCTAssertFalse([cohort.platform, cohort.treasury, cohort.buyback, cohort.graduation, cohort.factory, cohort.usdc].contains(request.to))
                }
            }
        }
    }

    /// The Portfolio's retired Moments: a cohort that can't be read keeps the Moments an earlier read had, and the read
    /// says it is incomplete; with nothing earlier, the cohort has none, still said. Every cohort read: complete.
    func testARetiredCohortThatCantBeReadKeepsItsMomentsAndSaysSo() async throws {
        let c3 = MomentsAddresses.retiredMainnet.first { $0.factory == MomentLink.Cohort.c3.factory }!
        let c2 = MomentsAddresses.retiredMainnet.first { $0.factory == MomentLink.Cohort.c2.factory }!
        let three = FakeMomentsStack(addresses: c3, policy: V2Fixture.policy(termsHash: nil), factoryBase: "", nftBase: "", names: ["Nature"])
        let two = FakeMomentsStack(addresses: c2, policy: V2Fixture.policy(termsHash: nil), factoryBase: "", nftBase: "", names: ["Two A", "Two B"])
        MomentsChainStub.install { to, data in three.answer(to, data) ?? two.answer(to, data) }
        let cohorts = [c3, c2].map { RetiredMoments(rpc: MomentsChainStub.rpc(), addresses: $0) }

        let first = await RetiredMoments.moments(of: cohorts)
        XCTAssertTrue(first.complete)
        XCTAssertEqual(first.moments.map(\.key), [MomentKey(factory: c3.factory, id: 1), MomentKey(factory: c2.factory, id: 2), MomentKey(factory: c2.factory, id: 1)])

        MomentsChainStub.install({ to, data in three.answer(to, data) ?? two.answer(to, data) }, breaking: [c2.factory])
        let second = await RetiredMoments.moments(of: cohorts, keeping: first.moments)
        XCTAssertFalse(second.complete, "a cohort couldn't be read")
        XCTAssertEqual(second.moments.map(\.key), first.moments.map(\.key), "its Moments from the earlier read stay")

        let fresh = await RetiredMoments.moments(of: cohorts)
        XCTAssertFalse(fresh.complete)
        XCTAssertEqual(fresh.moments.map(\.key), [MomentKey(factory: c3.factory, id: 1)])
    }
}
