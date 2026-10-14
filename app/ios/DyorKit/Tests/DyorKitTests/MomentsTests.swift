import BigInt
import XCTest
@testable import DyorKit

/// The Moments ABI surface pinned against Foundry and viem: every selector and event topic against `cast sig` /
/// `cast keccak`, whole calldata blobs against `cast calldata`, event decoders against `cast abi-encode` data, the
/// Permit2 digest against viem's `hashTypedData`, and the math against the live factory's `bundleRate`.
final class MomentsTests: XCTestCase {
    private let usdc = Address(literal: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603")
    private let collect = Address(literal: "0xb4EE9e67d9e1772BC6949748e3755EA7C1DFE32c")
    private let permit2 = Address(literal: "0x000000000022D473030F116dDEE9F6B43aC78BA3")

    // MARK: Selectors and topics (cast sig / cast keccak)

    func testSelectors() {
        // An array, not a dictionary: the collect contract and the hook share `withdrawCreator/withdrawPlatform(uint256)`.
        let expected: [(String, String)] = [
            (MomentsABI.Factory.policy, "0x0505c8c9"), (MomentsABI.Factory.momentCount, "0xc895d059"), (MomentsABI.Factory.publishingPaused, "0x788ab4ac"),
            (MomentsABI.Factory.externalBaseURI, "0xae8d070b"), (MomentsABI.Factory.getMoment, "0x557a2d20"), (MomentsABI.Factory.momentIdByCoin, "0x890d8e21"),
            (MomentsABI.Factory.publish, "0xa270dccc"), (MomentsABI.Collect.ledger, "0x10a7fd7b"), (MomentsABI.Collect.quote, "0x315f1a41"),
            (MomentsABI.Collect.collect, "0xcfa6f827"), (MomentsABI.Collect.collectWithPermit2, "0xd3d63b6d"), (MomentsABI.Collect.supplyCheck, "0xfd38ec3b"),
            (MomentsABI.Collect.expire, "0xbf81bf43"), (MomentsABI.Collect.withdrawCreator, "0x938a1499"), (MomentsABI.Collect.withdrawPlatform, "0xfbf16741"),
            (MomentsABI.Collect.withdrawTreasury, "0x11f1fc99"), (MomentsABI.Collect.state, "0x3e4f49e6"), (MomentsABI.Vesting.claim, "0x379607f5"),
            (MomentsABI.Vesting.claimAll, "0x28c77820"), (MomentsABI.Vesting.claimable, "0xa0c7f71c"), (MomentsABI.Vesting.entitlement, "0x8634ed8f"),
            (MomentsABI.Vesting.claimed, "0x120aa877"), (MomentsABI.Vesting.totalEntitlement, "0xbbf06424"), (MomentsABI.Vesting.creatorClaimed, "0xc6a67b3f"),
            (MomentsABI.Vesting.graduatedAt, "0x63f250c7"), (MomentsABI.Graduation.graduate, "0xf776449a"), (MomentsABI.Graduation.isGraduated, "0x95e0f8f4"),
            (MomentsABI.Graduation.record, "0x2c16cd8a"), (MomentsABI.Graduation.poolKeyOf, "0x18fe2928"), (MomentsABI.Locker.liquidityOf, "0x5f49a32c"),
            (MomentsABI.Hook.creatorAccrued, "0x2542a6f7"), (MomentsABI.Hook.platformAccrued, "0x63ce65fd"), (MomentsABI.Hook.buybackAccrued, "0xbfd0840e"),
            (MomentsABI.Hook.withdrawCreator, "0x938a1499"), (MomentsABI.Hook.withdrawPlatform, "0xfbf16741"), (MomentsABI.Buyback.carry, "0x044964ea"),
            (MomentsABI.Buyback.lastRun, "0x79f79edc"), (MomentsABI.Buyback.minInterval, "0xc0368740"), (MomentsABI.Buyback.minAmount, "0xddbcb5fa"),
            (MomentsABI.Buyback.execute, "0x5601eaea"), (MomentsABI.NFT.totalMinted, "0xa2309ff8"), (MomentsABI.NFT.closed, "0x597e1fb5"),
            (MomentsABI.NFT.provenance, "0x0f7309e8"), (MomentsABI.NFT.tokensOfOwner, "0xc839fe94"), (MomentsABI.NFT.ownerOf, "0x6352211e"),
            (MomentsABI.Coin.balanceOf, "0x70a08231"), (MomentsABI.Coin.name, "0x06fdde03"), (MomentsABI.Coin.symbol, "0x95d89b41"),
            (MomentsABI.Coin.totalSupply, "0x18160ddd"), (MomentsABI.PoolManager.extsload, "0x1e2eaeaf"),
            // v2 only.
            (MomentsABI.Factory.termsHash, "0xb311d9fd"), (MomentsABI.Factory.guardian, "0x452a9320"), (MomentsABI.Factory.guardianPaused, "0xfc7e29bd"),
            (MomentsABI.Factory.policyApplyWindow, "0xbfd9aa02"), (MomentsABI.NFT.externalBaseURI, "0xae8d070b"), (MomentsABI.Locker.available, "0x132d6d6b"),
            (MomentsABI.Locker.heldOf, "0x24fade37"), (MomentsABI.Locker.maxIncreaseBps, "0xd69aeb63"), (MomentsABI.Buyback.maxOpenDeviationBps, "0x346eb072"),
            (MomentsABI.Hook.blockOpenSqrtPrice, "0xa471add9"),
        ]
        for (signature, selector) in expected {
            XCTAssertEqual(ABI.selector(signature).hexString, selector, signature)
        }
    }

    func testEventTopics() {
        XCTAssertEqual(MomentsABI.Events.publishedTopic.hexString, "0xdb7fe8c848b875fe70036b24da1910e5e09c9ade908d9ddedbf970ae0fd7c8b7")
        XCTAssertEqual(MomentsABI.Events.collectedTopic.hexString, "0xc475c499a9357ec964b24130f5e1e4b21748160d33ce0df8721acb1e370b7c96")
        XCTAssertEqual(MomentsABI.Events.claimedTopic.hexString, "0xd9cb1e2714d65a111c0f20f060176ad657496bd47a3de04ec7c3d4ca232112ac")
        XCTAssertEqual(MomentsABI.Events.withdrawnTopic.hexString, "0xcf7d23a3cbe4e8b36ff82fd1b05b1b17373dc7804b4ebbd6e2356716ef202372")
        XCTAssertEqual(MomentsABI.Events.feesWithdrawnTopic.hexString, "0x538e1189c5c6413ddd9194fe5e947ef693ea737bd368a9e0aca4c286854c9bd8")
        XCTAssertEqual(MomentsABI.Events.graduatedTopic.hexString, "0xe1ab8964de99281028be12d5f904af6e5751e760418e5ccacce7f791ef9a893c")
        XCTAssertEqual(MomentsABI.Events.expiredTopic.hexString, "0xa3b1c5271df654763acdff6332b4163ebde3ec5cdd9ea040c16acc6504e3a3c0")
        XCTAssertEqual(MomentsABI.Events.feeTakenTopic.hexString, "0xf390f6f7846b730a86e28d011121b78c8010a3d9a94b63084de21f1afe63c7fc")
        XCTAssertEqual(MomentsABI.Events.buybackTopic.hexString, "0x77ee7be1f384fdbe7ff6bed2305a204a36e9ae69cedae791ae7dcf2e9dd963ca")
        XCTAssertEqual(MomentsABI.Events.transferTopic.hexString, "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
    }

    // MARK: Calldata (cast calldata)

    /// v2 `publish(PublishParams, bytes32 expectedTermsHash)`: the hash is the second head word, after the params' offset.
    func testPublishCalldata() {
        let input = MomentPublishInput(
            name: "Sunrise over Labadi", symbol: "LABADI",
            mediaURI: "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi", mediaHash: Data(repeating: 0x11, count: 32),
            animationURI: "", place: "Labadi Beach, Accra", date: 1_757_980_800, price: 1_000_000, creatorAllocBps: 1_000, collectWindow: 2_592_000
        )
        let hash = Data(hex: "0x3d9ff80b17a4f23544485081f1d595532c4f1d7932b3deea682e0b1e1fb2fa03")!
        let data = MomentsABI.calldata(MomentsABI.Factory.publish, [MomentsABI.publishParams(input, salt: Data(repeating: 0x22, count: 32)), .bytes(hash)])
        let expected = "0xa270dccc00000000000000000000000000000000000000000000000000000000000000403d9ff80b17a4f23544485081f1d595532c4f1d7932b3deea682e0b1e1fb2fa0300000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000f424000000000000000000000000000000000000000000000000000000000000003e80000000000000000000000000000000000000000000000000000000000278d002222222222222222222222222222222222222222222222222222222222222222000000000000000000000000000000000000000000000000000000000000001353756e72697365206f766572204c61626164690000000000000000000000000000000000000000000000000000000000000000000000000000000000000000064c4142414449000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0111111111111111111111111111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000068c8a88000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000042697066733a2f2f62616679626569676479727a74357366703775646d37687537367568377932366e6633656675796c71616266336f636c67747179353566627a646900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000134c61626164692042656163682c204163637261000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        XCTAssertEqual(data.hexString, expected)
    }

    func testCollectWithPermit2Calldata() {
        let permit = MomentsABI.permit(token: usdc, amount: 3_000_000, nonce: 12_345, deadline: 1_758_000_000)
        let data = MomentsABI.calldata(MomentsABI.Collect.collectWithPermit2, [.uint(7), .uint(3), permit, .bytes(Data([1, 2, 3, 4, 5]))])
        let expected = "0xd3d63b6d00000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000003000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60300000000000000000000000000000000000000000000000000000000002dc6c000000000000000000000000000000000000000000000000000000000000030390000000000000000000000000000000000000000000000000000000068c8f38000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000050102030405000000000000000000000000000000000000000000000000000000"
        XCTAssertEqual(data.hexString, expected)
    }

    func testClaimAllCalldata() {
        let data = MomentsABI.calldata(MomentsABI.Vesting.claimAll, [.array([.uint(1), .uint(2), .uint(3)])])
        XCTAssertEqual(data.hexString, "0x28c7782000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003")
    }

    // MARK: Permit2 (viem hashTypedData)

    func testPermit2Digest() throws {
        let permit = Permit2Signature.Permit(token: usdc, amount: 3_000_000, nonce: 12_345, deadline: 1_758_000_000)
        let digest = try Permit2Signature.digest(permit: permit, spender: collect, permit2: permit2, chainId: 143)
        XCTAssertEqual(digest.hexString, "0x9c6cdae544490e07bdb4e147131e002d1ac17349e535d2c8309425218f2db281")
    }

    func testRandomNonceIsWide() {
        let a = Permit2Signature.randomNonce()
        let b = Permit2Signature.randomNonce()
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThan(a.bitWidth, 200)
    }

    // MARK: Event decoding (cast abi-encode)

    private func log(topics: [Data], data: String, block: UInt64 = 105_400_000, index: Int = 3) -> Log {
        Log(address: collect, topics: topics, data: Data(hex: data)!, blockNumber: block, transactionHash: Data(repeating: 0xaa, count: 32), logIndex: index)
    }

    func testCollectedDecoding() {
        let collector = Address(literal: "0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8")
        let entry = log(
            topics: [MomentsABI.Events.collectedTopic, BigUInt(7).word, collector.data.leftPadded(to: 32)],
            data: "0x00000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000005955e3bb3e743fec0000000000000000000000000000000000000000000000000000000000000000b71b00000000000000000000000000000000000000000000000000000000000030d40000000000000000000000000000000000000000000000000000000000000c3500000000000000000000000000000000000000000000000000000000000000000"
        )
        let event = MomentsABI.collected(entry)
        XCTAssertEqual(event?.momentId, 7)
        XCTAssertEqual(event?.collector, collector)
        XCTAssertEqual(event?.gross, 1_000_000)
        XCTAssertEqual(event?.editions, 1)
        XCTAssertEqual(event?.firstRank, 5)
        XCTAssertEqual(event?.entitlement, BigUInt("6750000000000000000000000"))
        XCTAssertEqual(event?.reserveIn, 750_000)
        XCTAssertEqual(event?.creatorIn, 200_000)
        XCTAssertEqual(event?.platformIn, 50_000)
        XCTAssertEqual(event?.excess, 0)
        // Split identity: reserve + creator + platform == gross.
        XCTAssertEqual((event?.reserveIn ?? 0) + (event?.creatorIn ?? 0) + (event?.platformIn ?? 0), event?.gross)
    }

    func testPublishedClaimedWithdrawnDecoding() {
        let creator = Address(literal: "0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8")
        let published = MomentsABI.published(log(
            topics: [MomentsABI.Events.publishedTopic, BigUInt(1).word, creator.data.leftPadded(to: 32)],
            data: "0x0000000000000000000000003333333333333333333333333333333333333333000000000000000000000000444444444444444444444444444444444444444400000000000000000000000000000000000000000000000000000000000f424000000000000000000000000000000000000000000000000000000000000003e80000000000000000000000000000000000014cccfa4ebba1bf192683800000000000000000000000000000000000000000000000000000000006379da05b60000000000000000000000000000000000000000000000000000000000068e77800"
        ))
        XCTAssertEqual(published?.momentId, 1)
        XCTAssertEqual(published?.creator, creator)
        XCTAssertEqual(published?.coin, Address(literal: "0x3333333333333333333333333333333333333333"))
        XCTAssertEqual(published?.nft, Address(literal: "0x4444444444444444444444444444444444444444"))
        XCTAssertEqual(published?.price, 1_000_000)
        XCTAssertEqual(published?.creatorAllocBps, 1_000)
        XCTAssertEqual(published?.rateNum, BigUInt("6750000000000000000000000000000000"))
        XCTAssertEqual(published?.rateDen, BigUInt("1750000000000000"))
        XCTAssertEqual(published?.deadline, 1_760_000_000)

        let claimed = MomentsABI.claimed(log(
            topics: [MomentsABI.Events.claimedTopic, BigUInt(2).word, creator.data.leftPadded(to: 32)],
            data: "0x00000000000000000000000000000000000000000003599ef09f245bff400000000000000000000000000000000000000000000000108b2a2c28029094000000"
        ))
        XCTAssertEqual(claimed?.momentId, 2)
        XCTAssertEqual(claimed?.collectorAmount, BigUInt("4050000000000000000000000"))
        XCTAssertEqual(claimed?.creatorAmount, BigUInt("20000000000000000000000000"))

        var withdrawnLog = log(topics: [MomentsABI.Events.withdrawnTopic, BigUInt(3).word, creator.data.leftPadded(to: 32)], data: "0x0000000000000000000000000000000000000000000000000000000000030d40")
        XCTAssertEqual(MomentsABI.withdrawn(withdrawnLog)?.amount, 200_000)
        withdrawnLog = log(topics: [MomentsABI.Events.feesWithdrawnTopic, BigUInt(3).word, creator.data.leftPadded(to: 32)], data: "0x0000000000000000000000000000000000000000000000000000000000030d40")
        XCTAssertEqual(MomentsABI.withdrawn(withdrawnLog)?.momentId, 3)
        // A foreign topic is rejected.
        XCTAssertNil(MomentsABI.withdrawn(log(topics: [MomentsABI.Events.claimedTopic, BigUInt(3).word, creator.data.leftPadded(to: 32)], data: "0x0000000000000000000000000000000000000000000000000000000000030d40")))
    }

    func testHistoryAssembly() {
        let wallet = Address(literal: "0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8")
        let anchor = BlockHeader(number: 105_400_100, timestamp: 1_758_000_000)
        let collected = log(
            topics: [MomentsABI.Events.collectedTopic, BigUInt(7).word, wallet.data.leftPadded(to: 32)],
            data: "0x00000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000005955e3bb3e743fec0000000000000000000000000000000000000000000000000000000000000000b71b00000000000000000000000000000000000000000000000000000000000030d40000000000000000000000000000000000000000000000000000000000000c3500000000000000000000000000000000000000000000000000000000000000000",
            block: 105_400_000
        )
        let fees = log(topics: [MomentsABI.Events.feesWithdrawnTopic, BigUInt(7).word, wallet.data.leftPadded(to: 32)], data: "0x0000000000000000000000000000000000000000000000000000000000030d40", block: 105_400_050)
        let history = MomentsService.history(collected: [collected], claimed: [], withdrawn: [], feesWithdrawn: [fees], published: [], anchor: anchor,
                                             secondsPerBlock: BlockClockFixture.secondsPerBlock)
        XCTAssertEqual(history.collects.count, 1)
        XCTAssertEqual(history.collects[0].gross, 1_000_000)
        XCTAssertEqual(history.collects[0].platformIn, 50_000)
        // 100 blocks before the anchor at the pace two mainnet headers measured (0.30212 s) → 30.212 s earlier.
        XCTAssertEqual(history.collects[0].time.timeIntervalSince1970, 1_758_000_000 - 30.212, accuracy: 0.001)
        XCTAssertEqual(history.withdrawals.first?.kind, .poolFees)
        XCTAssertEqual(history.withdrawals.first?.amount, 200_000)
    }

    func testHolderStats() {
        let addresses = V2Fixture.moments
        let coin = Address(literal: "0x3333333333333333333333333333333333333333")
        let a = Address(literal: "0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8")
        let b = Address(literal: "0x5829268041d941e4E5594590B8133AC0319773A5")
        func transfer(_ from: Address, _ to: Address, _ coins: Int, block: UInt64) -> Log {
            Log(address: coin, topics: [MomentsABI.Events.transferTopic, from.data.leftPadded(to: 32), to.data.leftPadded(to: 32)],
                data: (BigUInt(coins) * BigUInt(10).power(18)).word, blockNumber: block, transactionHash: Data(repeating: 0xbb, count: 32), logIndex: 0)
        }
        let logs = [
            transfer(.zero, addresses.poolManager, 60, block: 1), // pool seed
            transfer(.zero, a, 30, block: 2), // claim
            transfer(.zero, b, 10, block: 3),
            transfer(a, b, 5, block: 4), // trade
        ]
        let stats = MomentsService.holderStats(transfers: logs, addresses: addresses, scannedTo: 4)
        XCTAssertEqual(stats.holders, 2)
        XCTAssertEqual(stats.mintedCoins, 100)
        XCTAssertEqual(stats.circulatingCoins, 40)
        XCTAssertEqual(stats.poolBps, 6_000)
        XCTAssertEqual(stats.topHolder, a)
        XCTAssertEqual(stats.topHolderBps, 6_250) // 25 of 40
    }

    // MARK: Math (factory bundleRate at the cohort-1 $10 policy and the cohort-2 $2,000-FDV policy)

    func testBundleRateMatchesFactory() {
        let rate = MomentsMath.bundleRate(threshold: 10_000_000, reserveBps: 7_500, creatorAllocBps: 1_000)
        XCTAssertEqual(rate.num, BigUInt("6750000000000000000000000000000000"))
        XCTAssertEqual(rate.den, BigUInt("1750000000000000"))
        // One 1 USDC collect at that rate: floor(1e6 · num / den) coin wei.
        XCTAssertEqual(MomentsMath.entitlement(gross: 1_000_000, rateNum: rate.num, rateDen: rate.den), BigUInt("3857142857142857142857142"))
        // Cohort 2 (factory 0xc12B…a581, threshold 771.428571 USDC): what the live factory stored for a 10%-allocation
        // Moment, and the terminal collect that lands the reserve exactly on the threshold (from the fork rehearsal).
        let cohort2 = MomentsMath.bundleRate(threshold: 771_428_571, reserveBps: 7_500, creatorAllocBps: 1_000)
        XCTAssertEqual(cohort2.num, BigUInt("6750000000000000000000000000000000"))
        XCTAssertEqual(cohort2.den, BigUInt("134999999925000000"))
        XCTAssertEqual(MomentsMath.entitlement(gross: 1_028_571_428, rateNum: cohort2.num, rateDen: cohort2.den), BigUInt("51428571428571428571428571"))
    }

    func testVestingSchedule() {
        let g = 1_700_000_000
        let month = MomentsConstants.monthSeconds
        XCTAssertEqual(MomentsMath.collectorVestedBps(graduatedAt: g, now: g - 1), 0)
        XCTAssertEqual(MomentsMath.collectorVestedBps(graduatedAt: g, now: g), 6_000)
        XCTAssertEqual(MomentsMath.collectorVestedBps(graduatedAt: g, now: g + month), 8_000)
        XCTAssertEqual(MomentsMath.collectorVestedBps(graduatedAt: g, now: g + 2 * month), 10_000)
        XCTAssertEqual(MomentsMath.creatorVestedBps(graduatedAt: g, now: g), 2_000)
        XCTAssertEqual(MomentsMath.creatorVestedBps(graduatedAt: g, now: g + 3 * month), 6_800)
        XCTAssertEqual(MomentsMath.creatorVestedBps(graduatedAt: g, now: g + 9 * month), 10_000)
        XCTAssertEqual(MomentsMath.creatorVestedBps(graduatedAt: 0, now: g), 0)
    }

    func testUsdcPerCoinAndProgress() {
        // sqrtPriceX96 for currency1/currency0 = 1e-12 raw (i.e. 1 whole USDC per whole coin when USDC is currency1).
        let ratio = 1e-12
        let sqrt = BigUInt(exactly: (ratio.squareRoot() * pow(2, 96)).rounded())!
        XCTAssertEqual(MomentsMath.usdcPerCoin(sqrtPriceX96: sqrt, usdcIs0: false), 1, accuracy: 1e-6)
        XCTAssertEqual(MomentsMath.usdcPerCoin(sqrtPriceX96: sqrt, usdcIs0: true), 1e24, accuracy: 1e18)
        XCTAssertEqual(MomentsMath.progressBps(reserve: 2_500_000, threshold: 10_000_000, state: .collecting), 2_500)
        XCTAssertEqual(MomentsMath.progressBps(reserve: 0, threshold: 10_000_000, state: .graduationPending), 10_000)
        XCTAssertEqual(MomentsMath.progressBps(reserve: 5, threshold: 0, state: .collecting), 0)
    }

    func testMediaURLRewrite() {
        // ipfs:// goes through DyorHQ's dedicated Pinata gateway first (see MomentsMediaTests for the full order).
        XCTAssertEqual(MomentsMath.url("ipfs://bafy123/photo.jpg")?.absoluteString, "https://scarlet-secure-kangaroo-820.mypinata.cloud/ipfs/bafy123/photo.jpg")
        XCTAssertEqual(MomentsMath.url("https://example.com/a.png")?.absoluteString, "https://example.com/a.png")
        XCTAssertNil(MomentsMath.url("javascript:alert(1)"))
        XCTAssertNil(MomentsMath.url(""))
    }

    func testMomentInfoDerivations() {
        let m = Moment(id: 1, creator: .zero, platform: .zero, treasury: .zero, coin: .zero, nft: .zero, price: 1_000_000, threshold: 10_000_000,
                       rateNum: 1, rateDen: 1, creatorBps: 2_000, platformBps: 500, reserveBps: 7_500, creatorAllocBps: 1_000, expiryCreatorBps: 7_000, royaltyBps: 500,
                       publishedAt: 1_000, deadline: 2_000)
        let ledger = MomentLedger(state: .collecting, completedAt: 0, stuckSince: 0, endedAt: 0, reserve: 2_250_000, creatorClaimable: 0, platformClaimable: 0, treasuryClaimable: 0, totalGross: 3_000_000, collects: 3)
        let info = MomentInfo(moment: m, name: "n", symbol: "S", provenance: MomentProvenance(mediaURI: "", mediaHash: Data(), place: "", date: 0, animationURI: ""),
                              ledger: ledger, editions: 3, closed: false, entitlements: 0, graduated: false, progressBps: 2_250, pool: nil)
        XCTAssertTrue(info.isCollecting(at: 1_999))
        XCTAssertFalse(info.isCollecting(at: 2_000))
        XCTAssertEqual(info.reserveRemaining, 7_750_000)
        XCTAssertEqual(info.collectsToGraduate, 11) // 7.75 USDC / 0.75 USDC per collect → 10.33 → 11
        XCTAssertTrue(info.isExpirable(at: 2_000))
        XCTAssertFalse(info.isExpirable(at: 1_999))
        XCTAssertEqual(m.creatorAllocation, BigUInt(10_000_000) * BigUInt(10).power(18))
    }
}

/// The RSS reader on a representative feed excerpt (RSS 2.0 with CDATA, media thumbnails and RFC 822 dates).
final class NewsTests: XCTestCase {
    func testParsesRSS() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><title>Feed</title><link>https://example.com</link>
        <item>
          <title><![CDATA[Bitcoin &amp; the market]]></title>
          <link>https://example.com/a</link>
          <guid isPermaLink="false">a-1</guid>
          <pubDate>Tue, 16 Sep 2026 10:30:00 +0000</pubDate>
          <description><![CDATA[<p>Some <b>bold</b> text &amp; more</p><img src="https://img.example.com/a.jpg" />]]></description>
          <media:thumbnail url="https://img.example.com/thumb.jpg" />
        </item>
        <item>
          <title>Second</title>
          <link>https://example.com/b</link>
          <pubDate>2026-09-16T09:00:00Z</pubDate>
          <description>plain</description>
        </item>
        </channel></rss>
        """
        let articles = RSSParser.parse(Data(xml.utf8), source: "Feed")
        XCTAssertEqual(articles.count, 2)
        XCTAssertEqual(articles[0].title, "Bitcoin & the market")
        XCTAssertEqual(articles[0].link.absoluteString, "https://example.com/a")
        XCTAssertEqual(articles[0].id, "a-1")
        XCTAssertEqual(articles[0].summary, "Some bold text & more")
        XCTAssertEqual(articles[0].imageURL?.absoluteString, "https://img.example.com/thumb.jpg")
        XCTAssertEqual(articles[0].published?.timeIntervalSince1970, 1_789_554_600)
        XCTAssertEqual(articles[1].published?.timeIntervalSince1970, 1_789_549_200)
        XCTAssertEqual(articles[1].id, "https://example.com/b")
    }
}
