import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// DyorHQ coins priced on the venue their own factory's record names, and nowhere else, with the 24h change read at the
/// block mined 24 hours before the latest (`BlockClock`). Runs PriceService's real RPC and Multicall code against
/// `VenueChainStub`, which answers each read at the block it names.
final class DyorVenuePricingTests: XCTestCase {
    // A chain 0.3 s a block: the latest block, the one 100,000 before it, and the one 24 hours back, mined on the second.
    static let head = BlockHeader(number: 2_000_000, timestamp: 1_800_000_000)
    static let dayAgo: UInt64 = 2_000_000 - 288_000
    static let live = LaunchpadAddresses.monadMainnet
    static let cohort = MomentsAddresses.monadMainnet
    /// The MON/USDC Uniswap v4 pool MON is priced from.
    static let monPool = PoolKey.canonical(Monad.native, Monad.usdc, fee: 500, tickSpacing: 10).id

    override func setUp() {
        VenueChainStub.reset(head: Self.head)
        VenueChainStub.header(Self.head.number - 100_000, Self.head.timestamp - 30_000)
        VenueChainStub.header(Self.dayAgo, Self.head.timestamp - 86_400)
        VenueChainStub.update { $0.liquidity[Self.monPool] = BigUInt(10).power(20) }
        // MON is $0.03 now and $0.025 a day ago: up 20%.
        monPrice(0.03)
        monPrice(0.025, at: Self.dayAgo)
    }

    /// A price service with DyorHQ venues on, as the app turns them on.
    private func service(registry: DyorCoinRegistry? = nil, clock: StubClock = StubClock()) -> PriceService {
        PriceService(rpc: VenueChainStub.rpc(), registry: registry, dyorVenues: true, now: { clock.now })
    }

    // MARK: Fixtures

    /// MON at `usd` in the MON/USDC v4 pool (MON is currency0), at `block` or any block.
    private func monPrice(_ usd: Double, at block: UInt64? = nil) {
        let sqrt = BigUInt((usd * 1e6 / 1e18).squareRoot() * pow(2, 96))
        VenueChainStub.answer(Uniswap.stateView, try! SwapCalldata.stateViewSlot0(poolId: Self.monPool), at: block,
                              with: try! ABI.encode([.uint(sqrt), .int(0), .uint(0), .uint(0)], "uint160,int24,uint24,uint24"))
    }

    /// The live launchpad's record of `coin` at `block` (or any block), in its 17-field layout.
    private func record(_ coin: Address, curve: Address, pair: Address = .zero, phase: LaunchPhase, venue: GraduationVenue = .uniswapV4,
                        poolId: Data = Data(count: 32), sweptAt: Int = 0, at block: UInt64? = nil) {
        let fields: [ABIValue] = [
            .address(coin), .address(curve), .address(Self.creator), .address(Self.creator), .address(pair), .uint(400), .uint(50), .uint(100), .int(60), .bool(false),
            .uint(BigUInt(venue.rawValue)), .uint(BigUInt(phase.rawValue)), .uint(0), .uint(0), .uint(BigUInt(sweptAt)), .bytes(poolId), .bool(true),
        ]
        let call = LaunchpadABI.call(Self.live.factory, LaunchpadABI.Factory.getLaunchedToken, [.address(coin)], returns: LaunchpadABI.launchedTokenTuple)
        VenueChainStub.answer(Self.live.factory, call, at: block, with: try! ABI.encode([.tuple(fields)], LaunchpadABI.launchedTokenTuple))
    }

    private func reserves(_ curve: Address, quote: BigUInt, tokens: BigUInt, at block: UInt64? = nil) {
        VenueChainStub.answer(curve, LaunchpadABI.call(curve, LaunchpadABI.Curve.getReserves, returns: "uint256,uint256"), at: block,
                              with: try! ABI.encode([.uint(quote), .uint(tokens)], "uint256,uint256"))
    }

    /// A v4 pool's slot0 word in `poolManager`, pricing currency1 per currency0 at `ratio` raw units.
    private func v4Slot(_ poolManager: Address, poolId: Data, ratio: Double, at block: UInt64? = nil) {
        let sqrt = BigUInt(ratio.squareRoot() * pow(2, 96))
        let call = LaunchpadABI.call(poolManager, LaunchpadABI.PoolManager.extsload, [.bytes(LaunchpadABI.slot0(of: poolId))], returns: "bytes32")
        VenueChainStub.answer(poolManager, call, at: block, with: sqrt.serialize().leftPadded(to: 32))
    }

    /// Moment `id` of the live cohort, its coin `coin`: its id, count and record, graduated into `key` or still `state`.
    private func moment(_ coin: Address, id: BigUInt, graduated key: PoolKey?, state: MomentState = .collecting) {
        let f = Self.cohort.factory
        VenueChainStub.answer(f, MomentsABI.call(f, MomentsABI.Factory.momentIdByCoin, [.address(coin)], returns: "uint256"), with: try! ABI.encode([.uint(id)], "uint256"))
        VenueChainStub.answer(f, MomentsABI.call(f, MomentsABI.Factory.momentCount, returns: "uint256"), with: try! ABI.encode([.uint(id)], "uint256"))
        let tuple: ABIValue = .tuple([.address(Self.creator), .address(.zero), .address(.zero), .address(coin), .address(Address(literal: "0x00000000000000000000000000000000000000f1")),
                                      .uint(100_000), .uint(771_428_571), .uint(1), .uint(1), .uint(2_000), .uint(500), .uint(7_500), .uint(1_000), .uint(7_000), .uint(500),
                                      .uint(1_790_000_000), .uint(1_790_086_400)])
        VenueChainStub.answer(f, MomentsABI.call(f, MomentsABI.Factory.getMoment, [.uint(id)], returns: MomentsABI.momentTuple), with: try! ABI.encode([tuple], MomentsABI.momentTuple))
        let g = Self.cohort.graduation
        VenueChainStub.answer(g, MomentsABI.call(g, MomentsABI.Graduation.isGraduated, [.uint(id)], returns: "bool"), with: try! ABI.encode([.bool(key != nil)], "bool"))
        if let key {
            let record: ABIValue = .tuple([.tuple([.address(key.currency0), .address(key.currency1), .uint(BigUInt(key.fee)), .int(BigInt(key.tickSpacing)), .address(key.hooks)]),
                                           .uint(1), .uint(1), .uint(0), .uint(0), .uint(0), .uint(0), .uint(1_799_000_000)])
            VenueChainStub.answer(g, MomentsABI.call(g, MomentsABI.Graduation.record, [.uint(id)], returns: MomentsABI.recordTuple), with: try! ABI.encode([record], MomentsABI.recordTuple))
        }
        let c = Self.cohort.collect
        let ledger: ABIValue = .tuple([.uint(BigUInt(state.rawValue)), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0)])
        VenueChainStub.answer(c, MomentsABI.call(c, MomentsABI.Collect.ledger, [.uint(id)], returns: MomentsABI.ledgerTuple), with: try! ABI.encode([ledger], MomentsABI.ledgerTuple))
    }

    static let creator = Address(literal: "0x00000000000000000000000000000000000000c0")
    private func coin(_ last: String, _ symbol: String = "COIN") -> Token {
        Token(address: Address(literal: "0x" + String(repeating: "0", count: 40 - last.count) + last), symbol: symbol, name: symbol, decimals: 18)
    }

    private func address(_ last: String) -> Address { Address(literal: "0x" + String(repeating: "0", count: 40 - last.count) + last) }

    // MARK: QT, recorded

    /// QT as read from mainnet with block 109,380,000 as the latest: the day-ago block is the one mined 24 hours earlier
    /// (109,094,104, after one correction), QT's Monday pool hadn't traded since, so its change is MON's and vs MON 0.00%.
    func testQTRecordedAtTheTrue24hBlock() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "qt-24h", withExtension: "json", subdirectory: "Fixtures"))
        let f = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
        func header(_ key: String) -> BlockHeader { BlockHeader(number: UInt64(f["headers"][key]["number"].number!), timestamp: Int(f["headers"][key]["timestamp"].number!)) }
        let head = header("head"), dayAgo = header("dayAgo")
        VenueChainStub.reset(head: head)
        for key in ["older", "estimate", "dayAgo"] { VenueChainStub.header(header(key).number, header(key).timestamp) }
        let qt = Token(address: Address(f["qt"].string!)!, symbol: "QT", name: "Quet", decimals: 18)
        let factory = Address(f["factory"].string!)!
        let pool = Address(f["qtPool"].string!)!
        let recordCall = LaunchpadABI.call(factory, LaunchpadABI.Factory.getLaunchedToken, [.address(qt.address)], returns: LaunchpadABI.legacyLaunchedTokenTuple)
        let slotCall = LaunchpadABI.call(pool, "slot0()", returns: "bytes32")
        let best = Data(hex: f["monV4"]["best"].string!)!
        for (key, block) in [("head", head.number), ("dayAgo", dayAgo.number)] {
            VenueChainStub.answer(factory, recordCall, at: block, with: Data(hex: f["qtRecord"][key].string!)!)
            VenueChainStub.answer(pool, slotCall, at: block, with: Data(hex: f["qtSlot0"][key].string!)!)
            VenueChainStub.answer(Uniswap.stateView, try SwapCalldata.stateViewSlot0(poolId: best), at: block, with: Data(hex: f["monV4"]["slot0"][key].string!)!)
        }
        for tier in f["monV4"]["tiers"].array! {
            let id = Data(hex: tier["poolId"].string!)!
            VenueChainStub.update { $0.liquidity[id] = BigUInt(Data(hex: tier["liquidity"].string!)!) }
        }

        let prices = try await service().prices(for: [qt, .mon])
        let price = try XCTUnwrap(prices[qt.address])
        let mon = try XCTUnwrap(prices[Monad.native])
        XCTAssertEqual(price.usd, 6.124e-8, accuracy: 0.001e-8, "about $6.12e-8")
        XCTAssertEqual(price.source, "Monday Trade")
        XCTAssertEqual(price.pairSymbol, "MON")
        XCTAssertFalse(price.isNew)
        XCTAssertEqual(try XCTUnwrap(price.pairChange), 0, accuracy: 1e-12, "vs MON 0.00%: the pool didn't trade")
        XCTAssertEqual(try XCTUnwrap(price.change24h), try XCTUnwrap(mon.change24h), accuracy: 1e-9, "its change is MON's")
        XCTAssertEqual(try XCTUnwrap(mon.change24h), 6.0467, accuracy: 0.0001)
        // Read at the block the clock corrected to, never at its first estimate.
        XCTAssertTrue(VenueChainStub.asked(at: dayAgo.number).contains { $0.to == pool })
        XCTAssertTrue(VenueChainStub.asked(at: header("estimate").number).isEmpty)
    }

    // MARK: Venues

    /// A USDC curve's price is about $1.2e-9 a coin: the curve's own `price()` rounds that to 0 (whole micro-dollars per
    /// 1e18 units); its reserves don't.
    func testAUSDCPairedCurveCoinIsPricedWithoutRounding() async throws {
        let token = coin("a1"), curve = address("c1")
        record(token.address, curve: curve, pair: Monad.usdc, phase: .bonding)
        reserves(curve, quote: 1_234_567, tokens: BigUInt(10).power(27))
        reserves(curve, quote: 1_000_000, tokens: BigUInt(10).power(27), at: Self.dayAgo)
        let prices = try await service().prices(for: [token])
        let price = try XCTUnwrap(prices[token.address])
        XCTAssertEqual(price.usd, 1.234567e-9, accuracy: 1e-21)
        XCTAssertEqual(price.source, "DyorHQ curve")
        XCTAssertEqual(price.pairSymbol, "USDC")
        XCTAssertEqual(try XCTUnwrap(price.change24h), 23.4567, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(price.pairChange), 23.4567, accuracy: 1e-9, "USDC is $1 at both blocks")
        XCTAssertFalse(VenueChainStub.snapshot.calls.contains { $0.to == curve && $0.data.prefix(4) == ABI.selector(LaunchpadABI.Curve.price) },
                       "the curve's rounded price() is never read")
    }

    func testAV4GraduatedCoinIsPricedFromItsPoolInTheLaunchpadsPoolManager() async throws {
        let token = coin("a2"), curve = address("c2")
        let poolId = Data(repeating: 0x42, count: 32)
        record(token.address, curve: curve, phase: .graduated, venue: .uniswapV4, poolId: poolId)
        // MON is currency0 (address 0): 500,000 coin units per MON unit, so 2e-6 MON a coin.
        v4Slot(Self.live.poolManager, poolId: poolId, ratio: 500_000)
        let priceRead = try await service().prices(for: [token])
        let price = try XCTUnwrap(priceRead[token.address])
        XCTAssertEqual(price.usd, 2e-6 * 0.03, accuracy: 1e-15)
        XCTAssertEqual(price.source, "Uniswap v4")
        XCTAssertEqual(try XCTUnwrap(price.pairChange), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(price.change24h), 20, accuracy: 1e-6, "MON's 20%")
    }

    func testAMomentIsPricedFromItsCohortsPool() async throws {
        let token = coin("a3")
        let key = PoolKey(currency0: token.address, currency1: Monad.usdc, fee: 10_000, tickSpacing: 200, hooks: Self.cohort.hook)
        moment(token.address, id: 3, graduated: key)
        // 0.0005 USDC a coin: 5e-16 USDC units per coin unit, the coin being currency0.
        let sqrt = BigUInt((5e-16).squareRoot() * pow(2, 96))
        VenueChainStub.answer(Self.cohort.poolManager, MomentsABI.call(Self.cohort.poolManager, MomentsABI.PoolManager.extsload, [.bytes(MomentsABI.slot0(of: key.id))], returns: "bytes32"),
                              with: sqrt.serialize().leftPadded(to: 32))
        let priceRead = try await service().prices(for: [token])
        let price = try XCTUnwrap(priceRead[token.address])
        XCTAssertEqual(price.usd, 0.0005, accuracy: 1e-12)
        XCTAssertEqual(price.source, "DyorHQ Moment pool")
        XCTAssertEqual(price.pairSymbol, "USDC")
        XCTAssertEqual(try XCTUnwrap(price.change24h), 0, accuracy: 1e-9)
    }

    func testACollectingMomentHasNoPrice() async throws {
        let token = coin("a4")
        moment(token.address, id: 4, graduated: nil, state: .collecting)
        let prices = service()
        let read = try await prices.prices(for: [token])
        XCTAssertNil(read[token.address], "no pool yet")
        let notTrading = await prices.notTradingYet([token])
        XCTAssertEqual(notTrading, [token.address], "the screen says Not trading yet")
        let without = await prices.withoutPool([token])
        XCTAssertEqual(without, [token.address], "simply no price, not a failed read")

        // One that expired never trades.
        let expired = coin("a5")
        moment(expired.address, id: 5, graduated: nil, state: .expired)
        _ = try await prices.prices(for: [expired])
        let expiredNotTrading = await prices.notTradingYet([expired])
        XCTAssertTrue(expiredNotTrading.isEmpty)
        let expiredWithout = await prices.withoutPool([expired])
        XCTAssertEqual(expiredWithout, [expired.address])
    }

    /// A Moment that graduates is priced from its pool within a minute of its last lookup, not 30: Home's row and its
    /// page stop saying "Not trading yet" while the Moments tab already values it.
    func testAMomentThatGraduatesIsPricedWithinAMinute() async throws {
        let token = coin("b1")
        moment(token.address, id: 6, graduated: nil, state: .collecting)
        let clock = StubClock()
        let prices = service(clock: clock)
        _ = try await prices.prices(for: [token])
        let collecting = await prices.notTradingYet([token])
        XCTAssertEqual(collecting, [token.address])

        let key = PoolKey(currency0: token.address, currency1: Monad.usdc, fee: 10_000, tickSpacing: 200, hooks: Self.cohort.hook)
        moment(token.address, id: 6, graduated: key, state: .graduated)
        let sqrt = BigUInt((5e-16).squareRoot() * pow(2, 96))
        VenueChainStub.answer(Self.cohort.poolManager, MomentsABI.call(Self.cohort.poolManager, MomentsABI.PoolManager.extsload, [.bytes(MomentsABI.slot0(of: key.id))], returns: "bytes32"),
                              with: sqrt.serialize().leftPadded(to: 32))
        clock.now = clock.now.addingTimeInterval(30)
        let soon = try await prices.prices(for: [token])
        XCTAssertNil(soon[token.address], "inside the minute the last record stands")
        clock.now = clock.now.addingTimeInterval(PoolLookupCache<Int>().unsettledTTL)
        let after = try await prices.prices(for: [token])
        XCTAssertEqual(try XCTUnwrap(after[token.address]).usd, 0.0005, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(after[token.address]).source, "DyorHQ Moment pool")
        let trading = await prices.notTradingYet([token])
        XCTAssertTrue(trading.isEmpty, "no longer Not trading yet")
    }

    /// A launch that graduates leaves its frozen curve price within a minute for its pool's; a coin already on its pool
    /// keeps its record for 30 minutes.
    func testALaunchThatGraduatesLeavesItsCurveWithinAMinute() async throws {
        let token = coin("b2"), curve = address("d2")
        let poolId = Data(repeating: 0x72, count: 32)
        record(token.address, curve: curve, phase: .bonding)
        reserves(curve, quote: 2 * BigUInt(10).power(18), tokens: BigUInt(10).power(24)) // 2e-6 MON a coin
        let clock = StubClock()
        let prices = service(clock: clock)
        let onCurve = try await prices.prices(for: [token])
        XCTAssertEqual(try XCTUnwrap(onCurve[token.address]).source, "DyorHQ curve")

        record(token.address, curve: curve, phase: .graduated, venue: .uniswapV4, poolId: poolId, sweptAt: Self.head.timestamp - 10)
        v4Slot(Self.live.poolManager, poolId: poolId, ratio: 1 / 3e-6) // 3e-6 MON a coin
        clock.now = clock.now.addingTimeInterval(PoolLookupCache<Int>().unsettledTTL + 1)
        let graduated = try await prices.prices(for: [token])
        XCTAssertEqual(try XCTUnwrap(graduated[token.address]).source, "Uniswap v4")
        XCTAssertEqual(try XCTUnwrap(graduated[token.address]).usd, 3e-6 * 0.03, accuracy: 1e-15)

        // On its pool it is settled: no record read at the latest block for the next 30 minutes.
        func recordReads() -> Int {
            VenueChainStub.asked(at: Self.head.number).filter { $0.to == Self.live.factory && $0.data.prefix(4) == ABI.selector(LaunchpadABI.Factory.getLaunchedToken) }.count
        }
        let reads = recordReads()
        clock.now = clock.now.addingTimeInterval(PoolLookupCache<Int>().hitTTL - 60)
        _ = try await prices.prices(for: [token])
        XCTAssertEqual(recordReads(), reads)
    }

    /// Graduated an hour ago: the 24h change compares its pool price now with its curve price a day ago, as its factory
    /// recorded it then; the chart reads the curve before the graduation and the pool after.
    func testAGraduationInsideTheWindow() async throws {
        let token = coin("a6"), curve = address("c6")
        let poolId = Data(repeating: 0x66, count: 32)
        let graduatedAt = Self.head.timestamp - 3_600
        record(token.address, curve: curve, phase: .graduated, venue: .uniswapV4, poolId: poolId, sweptAt: graduatedAt, at: Self.head.number)
        record(token.address, curve: curve, phase: .bonding, at: Self.dayAgo)
        v4Slot(Self.live.poolManager, poolId: poolId, ratio: 1 / 3e-6, at: Self.head.number) // 3e-6 MON a coin
        reserves(curve, quote: 2 * BigUInt(10).power(18), tokens: BigUInt(10).power(24)) // 2e-6 MON a coin on the curve
        let prices = service()
        let priceRead = try await prices.prices(for: [token])
        let price = try XCTUnwrap(priceRead[token.address])
        XCTAssertEqual(price.usd, 3e-6 * 0.03, accuracy: 1e-15)
        XCTAssertEqual(price.source, "Uniswap v4")
        XCTAssertEqual(try XCTUnwrap(price.pairChange), 50, accuracy: 1e-6, "pool now vs curve then, in MON")
        XCTAssertEqual(try XCTUnwrap(price.change24h), 80, accuracy: 1e-6, "in dollars: MON rose 20% too")

        // The chart: the curve at the three samples before the graduation, the pool after it, each at its block's MON price.
        let history = try await prices.history(for: token, points: 4)
        XCTAssertEqual(history.map(\.block), [Self.dayAgo, Self.dayAgo + 96_000, Self.dayAgo + 192_000, Self.head.number])
        XCTAssertEqual(history.map(\.usd)[0], 2e-6 * 0.025, accuracy: 1e-15)
        XCTAssertEqual(history.map(\.usd)[1], 2e-6 * 0.03, accuracy: 1e-15)
        XCTAssertEqual(history.map(\.usd)[3], 3e-6 * 0.03, accuracy: 1e-15)
        XCTAssertEqual(history[0].time.timeIntervalSince1970, TimeInterval(Self.head.timestamp - 86_400), accuracy: 1, "a true day, at the measured pace")
        XCTAssertFalse(VenueChainStub.asked(at: Self.dayAgo + 192_000).contains { $0.to == Self.live.poolManager }, "no pool before the graduation")
    }

    func testACoinYoungerThan24HoursIsNew() async throws {
        let token = coin("a7"), curve = address("c7")
        record(token.address, curve: curve, phase: .bonding, at: Self.head.number) // no record a day ago
        reserves(curve, quote: BigUInt(10).power(18), tokens: BigUInt(10).power(24))
        let priceRead = try await service().prices(for: [token])
        let price = try XCTUnwrap(priceRead[token.address])
        XCTAssertEqual(price.usd, 1e-6 * 0.03, accuracy: 1e-15)
        XCTAssertTrue(price.isNew)
        XCTAssertNil(price.change24h)
        XCTAssertNil(price.pairChange)
    }

    /// Someone plants a thin USDC pool for a DyorHQ coin at $1,000: the coin keeps its curve price, and no pool is even
    /// looked up for it. A coin the registry knows is asked of its own factory only.
    func testAPlantedThirdPartyPoolIsIgnored() async throws {
        let token = coin("a8", "PLNT"), curve = address("c8")
        let planted = address("b8")
        record(token.address, curve: curve, pair: Monad.usdc, phase: .bonding)
        reserves(curve, quote: 5_000_000, tokens: BigUInt(10).power(24)) // $5e-6
        VenueChainStub.answer(Uniswap.v3Factory, try SwapCalldata.v3GetPool(factory: Uniswap.v3Factory, token.address, Monad.usdc, fee: 3000), with: try ABI.encode([.address(planted)], "address"))
        VenueChainStub.answer(planted, try SwapCalldata.v3Liquidity(pool: planted), with: try ABI.encode([.uint(BigUInt(10).power(30))], "uint128"))
        VenueChainStub.answer(planted, try SwapCalldata.v3Token0(pool: planted), with: try ABI.encode([.address(token.address)], "address"))
        VenueChainStub.answer(planted, try SwapCalldata.v3Slot0(pool: planted),
                              with: try ABI.encode([.uint(BigUInt((1_000 * 1e6 / 1e18).squareRoot() * pow(2, 96))), .int(0), .uint(0), .uint(0), .uint(0), .uint(0), .bool(true)],
                                                   "uint160,int24,uint16,uint16,uint16,uint8,bool"))

        // The registry knows the coin (from its file).
        let file = FileManager.default.temporaryDirectory.appending(path: "venue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = DyorCoinStore(url: file)
        try store.save(DyorCoinStore.Snapshot(coins: [DyorCoin(address: token.address, origin: .launch(factory: Self.live.factory, generation: .v2, retired: false),
                                                               symbol: "PLNT", name: "Planted", creator: Self.creator, logo: "", pair: Monad.usdc)], checkpoints: []))
        let registry = DyorCoinRegistry(rpc: VenueChainStub.rpc(), store: store)
        let priceRead = try await service(registry: registry).prices(for: [token])
        let price = try XCTUnwrap(priceRead[token.address])
        XCTAssertEqual(price.usd, 5e-6, accuracy: 1e-18)
        XCTAssertEqual(price.source, "DyorHQ curve")
        let calls = VenueChainStub.snapshot.calls
        XCTAssertFalse(calls.contains { $0.to == planted }, "the planted pool is never read")
        XCTAssertFalse(calls.contains { $0.data.prefix(4) == ABI.selector("getPool(address,address,uint24)") && $0.data.range(of: token.address.data) != nil }, "nor looked up")
        XCTAssertFalse(calls.contains { $0.data.prefix(4) == ABI.selector(MomentsABI.Factory.momentIdByCoin) }, "a known coin's own factory only")

        // Unknown to the registry, with its factories' records unreadable: no price at all, never the planted pool's.
        let other = coin("a9"), otherCurve = address("c9")
        record(other.address, curve: otherCurve, pair: Monad.usdc, phase: .bonding)
        VenueChainStub.answer(Uniswap.v3Factory, try SwapCalldata.v3GetPool(factory: Uniswap.v3Factory, other.address, Monad.usdc, fee: 3000), with: try ABI.encode([.address(planted)], "address"))
        let blind = PriceService(rpc: VenueChainStub.rpc(), launchpads: [LaunchpadAddresses(factory: address("dead"), poolManager: Uniswap.poolManager)], cohorts: [], dyorVenues: true)
        let unread = try await blind.prices(for: [other])
        XCTAssertNil(unread[other.address], "a coin whose records couldn't be read is not priced from any pool")
        let without = await blind.withoutPool([other])
        XCTAssertTrue(without.isEmpty, "its price is unknown, not absent")
    }

    /// A read-only check against mainnet, run with `DYORHQ_LIVE_PRICES=1`: QT's price, 24h change and change vs MON now,
    /// printed, priced on its own Monday pool.
    func testLiveQTPrice() async throws {
        guard ProcessInfo.processInfo.environment["DYORHQ_LIVE_PRICES"] == "1" else { throw XCTSkip("Set DYORHQ_LIVE_PRICES=1 to read mainnet") }
        let service = PriceService(rpc: RPCClient(urls: Monad.publicRPCs), dyorVenues: true)
        let qt = Token(address: DyorCoinChain.qt, symbol: "QT", name: "Quet", decimals: 18)
        let prices = try await service.prices(for: [qt, .mon])
        let price = try XCTUnwrap(prices[qt.address])
        let mon = try XCTUnwrap(prices[Monad.native])
        let pace = await service.clock.secondsPerBlock()
        print("QT $\(price.usd) 24h \(price.change24h.map { String(format: "%.2f%%", $0) } ?? "-") vs \(price.pairSymbol ?? "?") \(price.pairChange.map { String(format: "%.2f%%", $0) } ?? "-") from \(price.source); MON $\(mon.usd) 24h \(mon.change24h.map { String(format: "%.2f%%", $0) } ?? "-"); \(pace) s a block")
        XCTAssertEqual(price.source, "Monday Trade")
        XCTAssertEqual(price.pairSymbol, "MON")
        XCTAssertFalse(price.isNew)
    }

    /// A USDC-paired DyorHQ curve coin at $5e-6 on its curve, with a third-party USDC pool beside it at $4e-6.
    private func curveCoinWithAPool() throws -> Token {
        let token = coin("aa"), curve = address("ca")
        let pool = address("ba")
        record(token.address, curve: curve, pair: Monad.usdc, phase: .bonding)
        reserves(curve, quote: 5_000_000, tokens: BigUInt(10).power(24))
        VenueChainStub.answer(Uniswap.v3Factory, try SwapCalldata.v3GetPool(factory: Uniswap.v3Factory, token.address, Monad.usdc, fee: 3000), with: try ABI.encode([.address(pool)], "address"))
        VenueChainStub.answer(pool, try SwapCalldata.v3Liquidity(pool: pool), with: try ABI.encode([.uint(BigUInt(10).power(18))], "uint128"))
        VenueChainStub.answer(pool, try SwapCalldata.v3Token0(pool: pool), with: try ABI.encode([.address(token.address)], "address"))
        VenueChainStub.answer(pool, try SwapCalldata.v3Slot0(pool: pool),
                              with: try ABI.encode([.uint(BigUInt((4e-6 * 1e6 / 1e18).squareRoot() * pow(2, 96))), .int(0), .uint(0), .uint(0), .uint(0), .uint(0), .bool(true)],
                                                   "uint160,int24,uint16,uint16,uint16,uint8,bool"))
        return token
    }

    /// Off unless asked for: until a screen counts each holding once, a new price service prices a DyorHQ coin as before
    /// and reads no factory record for it.
    func testVenuesAreOffUnlessAskedFor() async throws {
        let token = try curveCoinWithAPool()
        let read = try await PriceService(rpc: VenueChainStub.rpc()).prices(for: [token])
        let price = try XCTUnwrap(read[token.address])
        XCTAssertEqual(price.usd, 4e-6, accuracy: 1e-12)
        XCTAssertEqual(price.source, "Uniswap v3")
        XCTAssertNil(price.pairSymbol)
        XCTAssertFalse(VenueChainStub.snapshot.calls.contains { $0.data.prefix(4) == ABI.selector(LaunchpadABI.Factory.getLaunchedToken) }, "no record read")
    }

    /// Off (the remote switch), a DyorHQ coin is priced as before: from the deepest pool found for it.
    func testTheSwitchPricesDyorHQCoinsAsBefore() async throws {
        let token = try curveCoinWithAPool()
        let prices = service()
        let venueRead = try await prices.prices(for: [token])
        let venue = try XCTUnwrap(venueRead[token.address])
        XCTAssertEqual(venue.usd, 5e-6, accuracy: 1e-15)
        await prices.setUsesDyorVenues(false)
        let beforeRead = try await prices.prices(for: [token])
        let before = try XCTUnwrap(beforeRead[token.address])
        XCTAssertEqual(before.usd, 4e-6, accuracy: 1e-12)
        XCTAssertEqual(before.source, "Uniswap v3")
        XCTAssertNil(before.pairSymbol)
    }

    /// The switch turned off while a discovery reads the factories' records: what it found is dropped and looked up again
    /// without venues, rather than kept for 30 minutes in spite of the switch.
    func testTurningVenuesOffDuringADiscoveryIsNotUndone() async throws {
        let token = try curveCoinWithAPool()
        let prices = service()
        let records = VenueChainStub.hold(ABI.selector(LaunchpadABI.Factory.getLaunchedToken))
        async let offRead = prices.prices(for: [token])
        try await records.arrival()
        await prices.setUsesDyorVenues(false)
        records.release.signal()
        let off = try await offRead
        XCTAssertEqual(try XCTUnwrap(off[token.address]).source, "Uniswap v3", "found under the old setting: dropped")
        let offAgain = try await prices.prices(for: [token])
        XCTAssertEqual(try XCTUnwrap(offAgain[token.address]).usd, 4e-6, accuracy: 1e-12, "and not cached")
    }

    /// The switch turned on while a discovery reads the third-party pools: the coin is looked up on its own venue, never
    /// cached on the pool beside it.
    func testTurningVenuesOnDuringADiscoveryIsNotUndone() async throws {
        let token = try curveCoinWithAPool()
        let prices = PriceService(rpc: VenueChainStub.rpc())
        let pools = VenueChainStub.hold(ABI.selector("getPool(address,address,uint24)"))
        async let onRead = prices.prices(for: [token])
        try await pools.arrival()
        await prices.setUsesDyorVenues(true)
        pools.release.signal()
        let on = try await onRead
        XCTAssertEqual(try XCTUnwrap(on[token.address]).source, "DyorHQ curve", "the pool found under the old setting: dropped")
        let onAgain = try await prices.prices(for: [token])
        XCTAssertEqual(try XCTUnwrap(onAgain[token.address]).usd, 5e-6, accuracy: 1e-15, "and not cached")
    }
}
