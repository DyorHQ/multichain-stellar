import BigInt
import XCTest
@testable import DyorKit

/// What the wallet's lists (the Portfolio's Assets, the Send sheet) value DyorHQ's own coins at: a launch coin at its live
/// price in its pair asset, to a Double's precision — never `Launch.price`, whose whole units of a 6-decimal pair move in
/// steps of $0.000001, nor its curve's last price once graduated — and a Moment coin at its pool's live USDC price, never
/// its opening price. A coin whose launch, Moment or live price couldn't be read is unpriced, and the read says so.
/// Contract reads come from `MomentsChainStub`.
final class AppCoinValueTests: XCTestCase {
    private let owner = Address(literal: "0x7777777777777777777777777777777777777777")

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    private func service() -> LaunchpadService {
        LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: V2Fixture.launchpad, logsRPC: MomentsChainStub.rpc())
    }

    private func token(_ chain: HeldLaunchChain) -> Token {
        Token(address: chain.coin, symbol: "PEPE", name: "Pepe", decimals: 18, isLaunchpad: true)
    }

    // MARK: Launch coins

    /// The finding's coin: USDC-paired, on its curve at a true $0.0000035. `Launch.price` (the curve's `price()`, whole
    /// units of USDC's smallest unit) reads 3, so 50M coins would show $150; the live price reads the reserves: $175. At
    /// a true $0.0000009 `Launch.price` is 0, which would show $0; the live price still gives $45.
    func testAUSDCPairedCurveCoinIsValuedToTheCent() async throws {
        let held = BigUInt(50_000_000) * BigUInt(10).power(18)
        for (quote, expected, coarse) in [(BigUInt(3_500_000_000), 175.0, BigUInt(3)), (BigUInt(900_000_000), 45.0, BigUInt(0))] {
            let chain = HeldLaunchChain(deployer: owner, phase: .bonding, pair: Monad.usdc, reserves: (quote, BigUInt(10).power(27)))
            MomentsChainStub.install(chain.answer)
            let found = try await service().heldLaunches([.mon, .usdc, token(chain)])
            let launch = try XCTUnwrap(found.launches[chain.coin])
            XCTAssertEqual(launch.price, coarse, "Launch.price, as the curve's price() rounds it")
            XCTAssertEqual(try XCTUnwrap(found.pairPerCoin[chain.coin]), Double(quote) / 1e6 / 1e9, accuracy: 1e-18)
            XCTAssertEqual(launch.pairPrice, found.pairPerCoin[chain.coin], "one decimal price: the launch's own")
            XCTAssertEqual(try XCTUnwrap(launch.usdPrice(pairUSD: 1)), Double(quote) / 1e6 / 1e9, accuracy: 1e-18)
            XCTAssertTrue(found.complete)
            let prices = WalletHoldings.pricing([Monad.usdc: 1], launches: found, moments: [:])
            let ranked = WalletHoldings.ranked([token(chain)], balances: [chain.coin: held], prices: prices, unverified: [])
            XCTAssertEqual(try XCTUnwrap(ranked.first?.value), expected, accuracy: 1e-6)
        }
    }

    /// A graduated coin is valued at its pool's live price, read to a Double's precision; when that read fails it is
    /// unpriced — never the curve's last price, which its launch still carries — and the read is incomplete.
    func testAGraduatedCoinIsValuedAtItsPoolsLivePriceOrNotAtAll() async throws {
        let truePrice = 0.0000035 // USDC per coin
        let chain = HeldLaunchChain(deployer: owner, phase: .graduated, pair: Monad.usdc, reserves: (BigUInt(6_324_000_000), BigUInt(10).power(27)),
                                    sqrtPriceX96: HeldLaunchChain.sqrtPrice(usdcPerCoin: truePrice, coin: HeldLaunchChain.coinAddress, pair: Monad.usdc))
        MomentsChainStub.install(chain.answer)
        let found = try await service().heldLaunches([token(chain)])
        XCTAssertEqual(try XCTUnwrap(found.pairPerCoin[chain.coin]), truePrice, accuracy: truePrice * 1e-9)
        XCTAssertEqual(found.launches[chain.coin]?.price, 3, "Launch.price: the pool price rounded to whole units")
        XCTAssertTrue(found.complete)
        XCTAssertTrue(found.curve.coins.isEmpty, "a graduated coin trades on Swap")

        var unread = chain
        unread.sqrtPriceX96 = nil
        MomentsChainStub.install(unread.answer)
        let stale = try await service().heldLaunches([token(chain)])
        XCTAssertEqual(stale.launches[chain.coin]?.price, 6, "its launch falls back to the curve's last price…")
        XCTAssertNil(stale.pairPerCoin[chain.coin], "…which never values it")
        XCTAssertFalse(stale.complete)
        let prices = WalletHoldings.pricing([Monad.usdc: 1, chain.coin: 99], launches: stale, moments: [:])
        XCTAssertNil(prices[chain.coin], "unpriced: not the curve's price, nor another pool's")
    }

    /// Each launch coin's price and record come from one aggregate over every factory and one launch read per factory,
    /// which reads the live price with the launch (`Launch.pairPrice`); the coins still on a curve come from the same read
    /// (`HeldLaunches.curve`), so a list of holdings needs no second aggregate. A factory's answer missing throws: a coin
    /// could be missed.
    func testOneReadValuesAndRoutesAndAMissingAnswerThrows() async throws {
        let chain = HeldLaunchChain(deployer: owner, phase: .bonding, pair: .zero, reserves: (BigUInt(3) * BigUInt(10).power(18), BigUInt(10).power(22)))
        MomentsChainStub.install(chain.answer)
        let stranger = Token(address: Address(literal: "0x00000000000000000000000000000000000c0300"), symbol: "NEW", name: "New", decimals: 18)
        let found = try await service().heldLaunches([.mon, .usdc, token(chain), stranger])
        XCTAssertEqual(Set(found.factories.keys), [chain.coin])
        XCTAssertEqual(found.deployers[chain.coin], owner)
        XCTAssertEqual(found.pairAssets[chain.coin], .zero, "a MON-paired launch: MON's price, under address 0")
        XCTAssertEqual(try XCTUnwrap(found.pairPerCoin[chain.coin]), 0.0003, accuracy: 1e-15)
        XCTAssertEqual(found.curve.coins, [chain.coin])
        XCTAssertEqual(found.curve.route(chain.coin), .launchPage(try XCTUnwrap(found.launches[chain.coin])))
        let batches = MomentsChainStub.batches()
        let recordReads = batches.filter { $0.contains { $0.selector == ABI.selector(LaunchpadABI.Factory.getLaunchedToken).hexString } }
        XCTAssertEqual(recordReads.count, 1, "the factories are asked once")
        XCTAssertEqual(recordReads.first?.count, 2 * HeldLaunchChain.factories.count, "the coin and the stranger, of every factory; MON and USDC never")
        XCTAssertEqual(batches.filter { $0.contains { $0.selector == ABI.selector(LaunchpadABI.Curve.getReserves).hexString } }.count, 1)

        var silent = chain
        silent.silentFactories = [LaunchpadAddresses.retiredStacks[0].factory]
        MomentsChainStub.install(silent.answer)
        do {
            _ = try await service().heldLaunches([token(chain)])
            XCTFail("a factory that didn't answer must fail the read, not answer \"no launch\"")
        } catch {}
        MomentsChainStub.install({ _, _ in nil }, refusing: ["eth_call"])
        do {
            _ = try await service().heldLaunches([token(chain)])
            XCTFail("a read that failed must throw")
        } catch {}
        let none = try await service().heldLaunches([.mon, .usdc])
        XCTAssertEqual(none, .none)
    }

    /// A launch whose factory's launches can't be read is still recorded — its deployer and pair known — but has no
    /// launch and no price: unpriced, and the read is incomplete.
    func testALaunchThatCantBeReadIsUnpricedAndSaid() async throws {
        var chain = HeldLaunchChain(deployer: owner, phase: .bonding, pair: .zero, reserves: (BigUInt(3) * BigUInt(10).power(18), BigUInt(10).power(22)))
        chain.launchReads = false
        MomentsChainStub.install(chain.answer)
        let found = try await service().heldLaunches([token(chain)])
        XCTAssertEqual(Set(found.factories.keys), [chain.coin])
        XCTAssertEqual(found.deployers[chain.coin], owner)
        XCTAssertTrue(found.launches.isEmpty)
        XCTAssertNil(found.pairPerCoin[chain.coin])
        XCTAssertFalse(found.complete)
        XCTAssertEqual(found.curve.route(chain.coin), .launchUnread(LaunchReference(token: chain.coin, factory: V2Fixture.launchpad.factory), retired: false, phase: .bonding),
                       "still routed to its curve, from its record: its page opens by reference")
        XCTAssertNil(WalletHoldings.pricing([Monad.native: 0.03, chain.coin: 5], launches: found, moments: [:])[chain.coin])
    }

    /// The price math on its own: a curve's reserves in any pair's decimals; a v4 pool paired with native MON (the coin
    /// is currency1); a Monday Trade pool paired with WMON in MON's place, the coin on either side.
    func testThePairPriceMath() {
        let coin = HeldLaunchChain.coinAddress
        XCTAssertEqual(LaunchpadService.pairPerCoin([.uint(BigUInt(3_500_000_000)), .uint(BigUInt(10).power(27))], graduated: false, token: coin, pairSide: Monad.usdc, pairDecimals: 6)!,
                       0.0000035, accuracy: 1e-18)
        XCTAssertNil(LaunchpadService.pairPerCoin([.uint(1), .uint(0)], graduated: false, token: coin, pairSide: .zero, pairDecimals: 18), "an empty reserve")
        for (pairSide, price) in [(Address.zero, 0.0002), (Monad.wmon, 0.0002), (Address(literal: "0x0000000000000000000000000000000000000001"), 0.5)] {
            let sqrt = HeldLaunchChain.sqrtPrice(usdcPerCoin: price, coin: coin, pair: pairSide, pairDecimals: 18)
            let word = BigUInt(sqrt).word
            XCTAssertEqual(LaunchpadService.pairPerCoin([.bytes(word)], graduated: true, token: coin, pairSide: pairSide, pairDecimals: 18)!, price, accuracy: price * 1e-9, "\(pairSide.short)")
        }
        XCTAssertNil(LaunchpadService.pairPerCoin([.bytes(Data(count: 32))], graduated: true, token: coin, pairSide: .zero, pairDecimals: 18), "an uninitialised pool")
    }

    // MARK: Moment coins

    /// Many Moments are read in one read of the Moments and one hydration, not one round trip per coin; each carries its
    /// pool's live price, and a pool whose live read failed is marked so, at its opening price, which never values a coin.
    func testMomentsAreReadTogetherAndAnUnreadLivePriceNeverValuesACoin() async throws {
        let chain = GraduatedMoments(liveSqrt: HeldLaunchChain.sqrtPrice(usdcPerCoin: 0.02, coin: GraduatedMoments.coin(1), pair: Monad.usdc))
        MomentsChainStub.install(chain.answer)
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: V2Fixture.moments)
        let infos = try await service.infos(ids: [1, 2, 3, 2])
        XCTAssertEqual(infos.map(\.moment.id), [1, 2, 3])
        let momentReads = MomentsChainStub.batches().filter { $0.contains { $0.selector == ABI.selector(MomentsABI.Factory.getMoment).hexString } }
        XCTAssertEqual(momentReads.map(\.count), [3], "one read of the three Moments")
        XCTAssertLessThanOrEqual(MomentsChainStub.batches().count, 4, "their Moments, their ledgers, their pools and their live prices")
        for info in infos {
            let pool = try XCTUnwrap(info.pool)
            XCTAssertTrue(pool.livePriceRead)
            XCTAssertEqual(try XCTUnwrap(WalletHoldings.momentPrice(info)), MomentsMath.usdcPerCoin(sqrtPriceX96: chain.liveSqrt!, usdcIs0: pool.usdcIs0), accuracy: 1e-12)
        }

        var unread = chain
        unread.liveSqrt = nil
        MomentsChainStub.install(unread.answer)
        let stale = try await service.infos(ids: [1])
        let pool = try XCTUnwrap(stale.first?.pool)
        XCTAssertFalse(pool.livePriceRead)
        XCTAssertEqual(pool.sqrtPriceX96, GraduatedMoments.openingSqrt, "the page still shows the opening price…")
        XCTAssertNil(WalletHoldings.momentPrice(try XCTUnwrap(stale.first)), "…which never values a held coin")
    }

    /// Every screen that values a launch coin — Home's Launch tab, the Portfolio, the Launch board and page, My Launchpad —
    /// values it at its decimal price (`Launch.pairPrice`, through `DyorPrice.launch` or `Launch.usdPrice`), the same
    /// price Spot shows, and no app file values one at the integer `Launch.price` or the market cap made from it.
    func testEveryScreenValuesALaunchAtItsDecimalPrice() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let integer = try NSRegularExpression(pattern: #"priceNumber|LaunchpadMath\.marketCap\(|\b(launch|\$0|\$1)\.(price|marketCap)\b"#)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = integer.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
            XCTAssertEqual(hits, [], "\(file.lastPathComponent) values a launch at its integer price")
        }
        func source(_ path: String) throws -> String { try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8) }
        let home = try source("Home/HomeView.swift")
        XCTAssertTrue(home.contains("DyorPrice.launch(launch, spot: priceMap[launch.token]?.usd, pairUSD: pairUSD)"), "Home's Launch tab: Spot's price first")
        let portfolio = try source("Portfolio/PortfolioModel.swift")
        XCTAssertTrue(portfolio.contains("priced[launch.token] = DyorPrice.launch(launch, spot: fetchedPrices?[launch.token]?.usd,"))
        XCTAssertTrue(portfolio.contains("if let price = prices[token] { stats.pnl += delta * price } else { stats.pnlComplete = false }"), "the P&L at the same price")
        let launchpad = try source("Launchpad/LaunchpadView.swift")
        XCTAssertTrue(launchpad.contains("private var priceUSD: Double? { launch.usdPrice(pairUSD: pairUSD) }"))
        XCTAssertTrue(launchpad.contains("private var marketCapUSD: Double? { launch.marketCapInPair.flatMap { cap in pairUSD.map { cap * $0 } } }"))
        XCTAssertTrue(launchpad.contains("guard let current = launch.pairPrice.map({ $0 * unit }) else { return points }"))
        XCTAssertEqual(launchpad.components(separatedBy: "launch.marketCapInPair.map {").count - 1, 2, "the board card and the page header")
        // My Launchpad values a holding exactly as Home does: Spot's price, asked for every coin held in the same read as the
        // pair assets, else the coin's own decimal price; its profit and loss is measured against that same value.
        let profile = try source("Launchpad/LaunchpadProfileView.swift")
        XCTAssertTrue(profile.contains("let valueUSD = DyorPrice.launch(launch, spot: spotUSD[token], pairUSD: pairUSD).map { Amount.units(balance, decimals: 18) * $0 }"))
        XCTAssertTrue(profile.contains("let pairUSD = launch.pair.isNative ? self.pairUSD[Monad.native] : self.pairUSD[launch.pairToken]"), "the pair's price as Home picks it")
        XCTAssertTrue(profile.contains("} + heldCoins.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }"), "every coin held priced by Spot")
        XCTAssertTrue(profile.contains("spotUSD = Dictionary(heldCoins.compactMap { launch in DyorPrice.valid(priceMap[launch.token]?.usd).map { (launch.token, $0) } }"))
        XCTAssertFalse(profile.contains("spot: nil"), "never the curve price alone while Spot has one")
        XCTAssertTrue(profile.contains("history.launch.pnl(curve: launch.curve, pairDecimals: launch.pair.decimals, valueUSD: valueUSD, pairUSD: pairUSD)"))
    }

    /// The sources wire it in: the wallet's lists value DyorHQ's coins from `heldLaunches` and the Moments' live prices,
    /// say when a value couldn't be read, and route curve coins from the same read.
    func testTheWalletsListsValueDyorHQCoinsThisWay() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let tokens = try String(contentsOf: app.appendingPathComponent("Wallet/WalletTokens.swift"), encoding: .utf8)
        XCTAssertTrue(tokens.contains("async let launches = try? await launchpad.heldLaunches(candidates)"))
        XCTAssertTrue(tokens.contains("complete: (found?.complete ?? false) && coins.complete, curve: found?.curve)"))
        XCTAssertTrue(tokens.contains("let valued = WalletHoldings.pricing(pooled, launches: own.launches, moments: own.momentPrices)"))
        XCTAssertTrue(tokens.contains("pricesFailed: failed || !own.complete || !unpriced.unread.isEmpty, unpriced:"))
        XCTAssertTrue(tokens.contains("try? await live.infos(ids: Array(liveIds.values))"))
        XCTAssertTrue(tokens.contains("let price = WalletHoldings.momentPrice(info)"))
        XCTAssertFalse(tokens.contains("live.info(id:"), "never one round trip per Moment")
        XCTAssertFalse(tokens.contains("usdcPerCoin"), "a Moment coin is valued only at a live price")
        let assets = try String(contentsOf: app.appendingPathComponent("Portfolio/AssetsModel.swift"), encoding: .utf8)
        XCTAssertTrue(assets.contains("found = result.curve"))
        XCTAssertFalse(assets.contains("curveHoldings("), "the Portfolio asks the launchpads once")
    }
}

/// One coin launched on the live v2 fixture, answered from memory for `heldLaunches`: every known factory's
/// `getLaunchedToken` (the coin's record from the live one, an empty record in its own layout from every other, none from
/// `silentFactories`), the pair's metadata, the reads its launch is built from — its curve's `price()` computed from
/// `reserves` as the contract computes it, rounding down — its curve's `getReserves`, and its v4 pool's slot0.
struct HeldLaunchChain: Sendable {
    static let factories = [V2Fixture.launchpad] + LaunchpadAddresses.retiredStacks
    static let coinAddress = Address(literal: "0x00000000000000000000000000000000000c02d0")

    let deployer: Address
    var phase: LaunchPhase
    /// The pair asset: address 0 for MON.
    var pair: Address
    /// (quote reserve, token reserve), as `getReserves` answers; nil: it reverts.
    var reserves: (BigUInt, BigUInt)?
    /// The pool's sqrt price; nil: its slot0 read reverts.
    var sqrtPriceX96: BigUInt?
    var silentFactories: Set<Address> = []
    /// Off: the coin's own reads revert, so its launch can't be read.
    var launchReads = true
    let coin = coinAddress
    let curve = Address(literal: "0x00000000000000000000000000000000000c02c0")
    let poolId = Data(repeating: 0x11, count: 32)

    init(deployer: Address, phase: LaunchPhase, pair: Address, reserves: (BigUInt, BigUInt)?, sqrtPriceX96: BigUInt? = nil) {
        self.deployer = deployer
        self.phase = phase
        self.pair = pair
        self.reserves = reserves
        self.sqrtPriceX96 = sqrtPriceX96
    }

    /// The sqrtPriceX96 of a pool pricing `coin` (18 decimals) at `usdcPerCoin` whole units of `pair` (`pairDecimals`).
    static func sqrtPrice(usdcPerCoin price: Double, coin: Address, pair: Address, pairDecimals: Int = 6) -> BigUInt {
        let raw = price * pow(10, Double(pairDecimals - 18)) // pair raw per coin raw
        let coinIs0 = BigUInt(coin.data) < BigUInt(pair.data)
        let price1Per0 = coinIs0 ? raw : 1 / raw
        return BigUInt(exactly: (price1Per0.squareRoot() * pow(2, 96)).rounded())!
    }

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        let args = ABIWords(data.dropFirst(4))
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        typealias T = LaunchpadABI.Token
        typealias C = LaunchpadABI.Curve
        if is_(LaunchpadABI.Factory.getLaunchedToken), let known = Self.factories.first(where: { $0.factory == to }) {
            if silentFactories.contains(to) { return nil }
            let legacy = known.generation.legacyRecord
            let ours = to == V2Fixture.launchpad.factory && args.address(0) == coin
            var fields: [ABIValue] = [.address(ours ? coin : .zero), .address(ours ? curve : .zero), .address(ours ? deployer : .zero), .address(ours ? deployer : .zero),
                                      .address(ours ? pair : .zero), .uint(4_324), .uint(0), .uint(100), .int(60), .bool(false),
                                      .uint(BigUInt(GraduationVenue.uniswapV4.rawValue)), .uint(BigUInt((ours ? phase : .bonding).rawValue)), .uint(0), .uint(0), .uint(0),
                                      .bytes(ours ? poolId : Data(count: 32)), .bool(ours)]
            if legacy { fields.remove(at: 10) }
            return encode([.tuple(fields)], LaunchpadABI.launchedTokenReturns(legacy: legacy))
        }
        if to == Monad.usdc {
            if is_(T.symbol) { return encode([.string("USDC")], "string") }
            if is_(T.decimals) { return encode([.uint(6)], "uint8") }
        }
        if to == coin, launchReads {
            if is_(T.name) { return encode([.string("Pepe")], "string") }
            if is_(T.symbol) { return encode([.string("PEPE")], "string") }
            if is_(T.totalSupply) { return encode([.uint(BigUInt(10).power(27))], "uint256") }
            if is_(T.getTokenInfo) { return encode([.address(coin), .string(""), .string(""), .tuple(Array(repeating: .string(""), count: 5))], "address,string,string,\(LaunchpadABI.socialsTuple)") }
        }
        if to == curve, launchReads {
            if is_(C.price), let (quote, tokens) = reserves { return encode([.uint(quote * BigUInt(10).power(18) / tokens)], "uint256") }
            if is_(C.realQuoteReserve) { return encode([.uint(1_000)], "uint256") }
            if is_(C.completed) { return encode([.bool(phase == .graduated)], "bool") }
            if is_(C.rescued) { return encode([.bool(false)], "bool") }
            if is_(C.launchedAt) { return encode([.uint(1_789_000_000)], "uint64") }
            if is_(C.getReserves), let (quote, tokens) = reserves { return encode([.uint(quote), .uint(tokens)], "uint256,uint256") }
        }
        if to == V2Fixture.launchpad.poolManager, is_(LaunchpadABI.PoolManager.extsload), args.word(0) == LaunchpadABI.slot0(of: poolId), let sqrtPriceX96 {
            return sqrtPriceX96.word
        }
        return nil
    }
}

/// Three graduated Moments on the v2 fixture (`FakeMomentsStack`), each with its pool: the graduation record at
/// `openingSqrt`, and the PoolManager's live slot0 at `liveSqrt` (nil: that read reverts).
struct GraduatedMoments: Sendable {
    static let openingSqrt = BigUInt(2).power(96) / 1_000
    static func coin(_ id: Int) -> Address { stack.coin(id) }
    static let stack = FakeMomentsStack(addresses: V2Fixture.moments, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                        nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["One", "Two", "Three"])
    var liveSqrt: BigUInt?

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        let args = ABIWords(data.dropFirst(4))
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        let a = V2Fixture.moments
        let id = args.uint(0).flatMap { Int(exactly: $0) } ?? 0
        switch to {
        case a.graduation:
            if is_(MomentsABI.Graduation.isGraduated) { return encode([.bool(true)], "bool") }
            if is_(MomentsABI.Graduation.record) {
                let key: ABIValue = .tuple([.address(a.usdc), .address(Self.coin(id)), .uint(5_000), .int(60), .address(a.hook)])
                return encode([.tuple([key, .uint(Self.openingSqrt), .uint(1_000), .uint(0), .uint(0), .uint(0), .uint(0), .uint(1_790_000_000)])], MomentsABI.recordTuple)
            }
        case a.locker:
            if is_(MomentsABI.Locker.liquidityOf) { return encode([.uint(1_000)], "uint128") }
            if is_(MomentsABI.Locker.heldOf) { return encode([.uint(0)], "uint256") }
        case a.hook:
            if is_(MomentsABI.Hook.creatorAccrued) || is_(MomentsABI.Hook.platformAccrued) || is_(MomentsABI.Hook.buybackAccrued) { return encode([.uint(0)], "uint256") }
        case a.buyback:
            if is_(MomentsABI.Buyback.carry) || is_(MomentsABI.Buyback.minInterval) || is_(MomentsABI.Buyback.minAmount) { return encode([.uint(0)], "uint256") }
            if is_(MomentsABI.Buyback.lastRun) { return encode([.uint(0)], "uint64") }
        case a.poolManager:
            if is_(MomentsABI.PoolManager.extsload) { return liveSqrt.map(\.word) }
        default:
            break
        }
        return Self.stack.answer(to, data)
    }
}
