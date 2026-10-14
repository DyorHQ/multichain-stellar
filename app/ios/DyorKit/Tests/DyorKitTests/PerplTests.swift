import BigInt
import XCTest
@testable import DyorKit

/// Fixtures/perpl.json was produced with viem and live `eth_call`s against Perpl's Exchange on Monad mainnet;
/// Fixtures/perpl-context.json is a real response of Perpl's public context endpoint. The service is driven
/// through a replaying URLProtocol so the real `RPCClient` and `Multicall` code paths are exercised.
final class PerplTests: XCTestCase {
    private static let fixture: JSON = {
        let url = Bundle.module.url(forResource: "perpl", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
    }()

    private static let contextBody: Data = {
        let url = Bundle.module.url(forResource: "perpl-context", withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }()

    private var f: JSON { Self.fixture }
    private let exchange = Perpl.exchange
    private let marketIds = [1, 10, 20, 31, 40, 50]

    override func setUp() {
        super.setUp()
        PerplMockTransport.reset()
    }

    private func makeService() -> PerplService {
        let session = PerplMockTransport.session()
        return PerplService(rpc: RPCClient(url: Monad.defaultRPC, session: session), session: session)
    }

    // MARK: Fixture helpers

    private func hex(_ s: String) -> Data { Data(hex: s)! }

    private func desc(from json: JSON) -> [ABIValue] {
        func u(_ key: String) -> ABIValue { .uint(BigUInt(json[key].string!)!) }
        func b(_ key: String) -> ABIValue { .bool(json[key].bool!) }
        return [
            u("orderDescId"), u("perpId"), .uint(Int(json["orderType"].number!)), u("orderId"), u("pricePNS"), u("lotLNS"), u("expiryBlock"),
            b("postOnly"), b("fillOrKill"), b("immediateOrCancel"), u("maxMatches"), u("leverageHdths"), u("lastExecutionBlock"), u("amountCNS"), u("maxNegPnlCollatBPS"),
        ]
    }

    /// Registers a live read from the fixture (`{calldata, ok, data | error}`) with the mock transport.
    private func install(_ entry: JSON) {
        let calldata = entry["calldata"].string!
        if entry["ok"].bool == true {
            PerplMockTransport.replies[calldata] = .ok(hex(entry["data"].string!))
        } else {
            PerplMockTransport.replies[calldata] = .revert(hex(entry["error"]["data"].string ?? "0x"))
        }
    }

    private func install(_ signature: String, _ args: [ABIValue], returning values: [ABIValue], types: String) {
        let calldata = PerplExchange.calldata(signature, args).hexString
        PerplMockTransport.replies[calldata] = .ok(try! ABI.encode(values, try! ABIType.parseList(types)))
    }

    private func installMarkets() {
        for id in marketIds { install(f["chain"]["perpetualInfo"][String(id)]) }
        install(f["chain"]["marginFractions10"])
    }

    private func market(_ id: Int, mark: Double? = nil) -> PerpMarket {
        let entry = f["chain"]["perpetualInfo"][String(id)]
        let info = try! ABI.decode(hex(entry["data"].string!), PerplExchange.Returns.perpetualInfo)[0]
        let margins = id == 10 ? try! ABI.decode(hex(f["chain"]["marginFractions10"]["data"].string!), PerplExchange.Returns.marginFractions) : nil
        let m = PerplExchange.market(id: id, info: info, margins: margins)
        guard let mark else { return m }
        return PerpMarket(id: m.id, symbol: m.symbol, name: m.name, priceDecimals: m.priceDecimals, lotDecimals: m.lotDecimals, basePricePNS: m.basePricePNS, mark: mark, last: m.last, oracle: m.oracle, markTimestamp: m.markTimestamp, longOI: m.longOI, shortOI: m.shortOI, fundingRatePct100k: m.fundingRatePct100k, status: m.status, initMarginFraction: m.initMarginFraction, maintMarginFraction: m.maintMarginFraction, numOrders: m.numOrders)
    }

    private func descTuple(in calldata: Data, at index: Int = 0) -> ABIValue {
        let types = try! ABI.parameterTypes(of: PerplExchange.Signature.execOrders)
        return try! ABI.decode(calldata.dropFirst(4), types)[0][index]
    }

    /// The viem vector with its time-based `orderDescId` swapped for ours, so the rest compares byte for byte.
    private func assertExecOrders(_ steps: [TransactionStep], matches key: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(steps.count, 1, file: file, line: line)
        guard let request = steps.first?.request else { return XCTFail("no call step", file: file, line: line) }
        XCTAssertEqual(request.to, exchange, file: file, line: line)
        XCTAssertEqual(request.value, 0, file: file, line: line)
        let expected = hex(f["calldata"][key].string!)
        let ours = descTuple(in: request.data)
        var reference = descTuple(in: expected).elements
        reference[0] = ours[0]
        // Our calldata must equal the viem vector once its time-based orderDescId is swapped for ours.
        let patched = PerplExchange.execOrdersCalldata([reference], revertOnFail: true)
        XCTAssertEqual(request.data.hexString, patched.hexString, key, file: file, line: line)
    }

    // MARK: Calldata against viem

    func testSelectorsAndReadCalldataMatchViem() {
        // The account-missing revert selector 0x03a0e277 is taken from a live revert, not a guessed error name.
        XCTAssertEqual(PerplExchange.accountNotFoundSelector, "0x03a0e277")
        XCTAssertTrue(PerplExchange.isAccountNotFound(RPCError(code: 3, message: "execution reverted", data: "0x03a0e277000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb603")))
        let reads: [(String, [ABIValue], String)] = [
            (PerplExchange.Signature.getPerpetualInfo, [.uint(10)], "getPerpetualInfo10"),
            (PerplExchange.Signature.getMarginFractions, [.uint(10), .uint(0)], "getMarginFractions10"),
            (PerplExchange.Signature.getAccountByAddr, [.address(Monad.ausd)], "getAccountByAddr"),
            (PerplExchange.Signature.getPosition, [.uint(10), .uint(1)], "getPosition10_1"),
            (PerplExchange.Signature.getPerpOrderLocks, [.uint(1), .uint(10)], "getPerpOrderLocks1_10"),
            (PerplExchange.Signature.getOrderIdIndex, [.uint(10)], "getOrderIdIndex10"),
            (PerplExchange.Signature.getOrder, [.uint(10), .uint(1)], "getOrder10_1"),
        ]
        for (signature, args, key) in reads {
            XCTAssertEqual(PerplExchange.calldata(signature, args).hexString, f["calldata"][key].string!, key)
            XCTAssertEqual(PerplExchange.read(signature, args, returns: "uint256").data.hexString, f["calldata"][key].string!, key)
        }
        // The live reads in the fixture were made with the same calldata the service builds.
        XCTAssertEqual(f["chain"]["perpetualInfo"]["10"]["calldata"].string, f["calldata"]["getPerpetualInfo10"].string)
        XCTAssertEqual(f["chain"]["accountByAddrCollateral"]["calldata"].string, f["calldata"]["getAccountByAddr"].string)
    }

    func testCollateralPlansMatchViem() {
        let amount = BigUInt(f["sampleDescs"]["amountCNS"].string!)!
        let service = makeService()

        let open = service.depositPlan(amountCNS: amount, hasAccount: false)
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(open[0].kind, .approve(token: Perpl.collateral, spender: exchange, amount: amount))
        XCTAssertEqual(try ERC20.approveCalldata(spender: exchange, amount: amount).hexString, f["calldata"]["approveCollateral"].string!)
        XCTAssertEqual(open[1].request?.to, exchange)
        XCTAssertEqual(open[1].request?.data.hexString, f["calldata"]["createAccount"].string!)

        let topUp = service.depositPlan(amountCNS: amount, hasAccount: true)
        XCTAssertEqual(topUp[0].kind, .approve(token: Perpl.collateral, spender: exchange, amount: amount))
        XCTAssertEqual(topUp[1].request?.data.hexString, f["calldata"]["depositCollateral"].string!)

        let withdraw = service.withdrawPlan(amountCNS: amount)
        XCTAssertEqual(withdraw.count, 1)
        XCTAssertEqual(withdraw[0].kind, .call)
        XCTAssertEqual(withdraw[0].request?.to, exchange)
        XCTAssertEqual(withdraw[0].request?.data.hexString, f["calldata"]["withdrawCollateral"].string!)
    }

    func testExecOrdersEncodingMatchesViem() {
        let market = desc(from: f["sampleDescs"]["market"])
        let cancel = desc(from: f["sampleDescs"]["cancel"])
        let limit = desc(from: f["sampleDescs"]["limit"])
        XCTAssertEqual(PerplExchange.execOrdersCalldata([market], revertOnFail: true).hexString, f["calldata"]["execOrdersMarket"].string!)
        XCTAssertEqual(PerplExchange.execOrdersCalldata([cancel], revertOnFail: true).hexString, f["calldata"]["execOrdersCancel"].string!)
        XCTAssertEqual(PerplExchange.execOrdersCalldata([limit], revertOnFail: true).hexString, f["calldata"]["execOrdersLimit"].string!)
        XCTAssertEqual(PerplExchange.execOrdersCalldata([market, cancel], revertOnFail: false).hexString, f["calldata"]["execOrdersTwo"].string!)
    }

    func testOrderPlansMatchViem() {
        let service = makeService()
        // viem's market sample: MON, open long, pricePNS 12345, lot 500, IOC, 5x. A mark of 0.012223 with 1%
        // slippage rounds to exactly 12345 in price units.
        let mon = market(10, mark: 0.012223)
        XCTAssertEqual(mon.priceDecimals, 6)
        XCTAssertEqual(mon.lotDecimals, 0)
        assertExecOrders(service.orderPlan(OrderInput(market: mon, side: .long, kind: .market, size: 500, leverage: 5)), matches: "execOrdersMarket")

        // viem's limit sample: BTC, open short, post-only limit at 651234500000.0, 0.125 contracts, 20x.
        let btc = market(1)
        XCTAssertEqual(btc.priceDecimals, 1)
        XCTAssertEqual(btc.lotDecimals, 5)
        assertExecOrders(service.orderPlan(OrderInput(market: btc, side: .short, kind: .limit, size: 0.125, price: 651_234_500_000, leverage: 20, postOnly: true)), matches: "execOrdersLimit")

        assertExecOrders(service.cancelPlan(perpId: 20, orderId: 77), matches: "execOrdersCancel")
    }

    // MARK: Order descriptions

    func testMarketOrdersUseIOCAndSlippage() {
        let mon = market(10)
        let long = PerplService.buildOrderDesc(OrderInput(market: mon, side: .long, kind: .market, size: 1000, leverage: 3.5, slippageBps: 50, postOnly: true))
        XCTAssertEqual(long.count, 15)
        XCTAssertEqual(long[1].uint, 10)
        XCTAssertEqual(long[2].uint, BigUInt(PerpOrderType.openLong.rawValue))
        XCTAssertEqual(long[4].uint, BigUInt(exactly: PerplExchange.jsRound(mon.mark * (1 + 0.005) * 1e6)))
        XCTAssertEqual(long[5].uint, 1000)
        XCTAssertEqual(long[7].bool, false, "post-only is ignored for market orders")
        XCTAssertEqual(long[8].bool, false)
        XCTAssertEqual(long[9].bool, true, "market orders are immediate-or-cancel")
        XCTAssertEqual(long[11].uint, 350)
        XCTAssertEqual(long[14].uint, 300)

        let short = PerplService.buildOrderDesc(OrderInput(market: mon, side: .short, kind: .market, size: 1000, leverage: 2))
        XCTAssertEqual(short[2].uint, BigUInt(PerpOrderType.openShort.rawValue))
        XCTAssertEqual(short[4].uint, BigUInt(exactly: PerplExchange.jsRound(mon.mark * (1 - 0.01) * 1e6)))

        let reduceLong = PerplService.buildOrderDesc(OrderInput(market: mon, side: .long, kind: .market, size: 1, leverage: 1, reduceOnly: true))
        XCTAssertEqual(reduceLong[2].uint, BigUInt(PerpOrderType.closeShort.rawValue))
        let reduceShort = PerplService.buildOrderDesc(OrderInput(market: mon, side: .short, kind: .market, size: 1, leverage: 1, reduceOnly: true))
        XCTAssertEqual(reduceShort[2].uint, BigUInt(PerpOrderType.closeLong.rawValue))

        let limit = PerplService.buildOrderDesc(OrderInput(market: mon, side: .long, kind: .limit, size: 250, price: 0.02, leverage: 10, postOnly: true))
        XCTAssertEqual(limit[4].uint, 20_000)
        XCTAssertEqual(limit[7].bool, true)
        XCTAssertEqual(limit[9].bool, false)
        let zeroPriceLimit = PerplService.buildOrderDesc(OrderInput(market: mon, side: .long, kind: .limit, size: 250, price: 0, leverage: 10))
        XCTAssertEqual(zeroPriceLimit[4].uint, BigUInt(exactly: PerplExchange.jsRound(mon.mark * (1 + 0.01) * 1e6))!, "a zero limit price falls back to mark and default slippage")
        XCTAssertEqual(zeroPriceLimit[9].bool, false, "still a limit order")
    }

    func testOrderDescIdsStrictlyIncrease() {
        let mon = market(10)
        let before = UInt64(Date().timeIntervalSince1970 * 1000)
        var last = BigUInt(0)
        for _ in 0..<50 {
            let id = PerplService.buildOrderDesc(OrderInput(market: mon, side: .long, kind: .market, size: 1, leverage: 1))[0].uint
            XCTAssertGreaterThan(id, last)
            last = id
        }
        XCTAssertGreaterThanOrEqual(last, BigUInt(before))
        XCTAssertLessThan(last, BigUInt(before) + 60_000, "ids stay within a minute of the wall clock")
    }

    func testJavaScriptRounding() {
        for c in f["roundCases"].array! {
            let value = c["value"].number!
            XCTAssertEqual(PerplExchange.jsRound(value), c["round"].number!, "Math.round(\(value))")
            XCTAssertEqual(PerplExchange.jsRound(value * 1e6), c["cns"].number!, "Math.round(\(value) * 1e6)")
            let cns = c["cns"].number!
            XCTAssertEqual(PerplService.toCNS(value), cns < 0 ? 0 : BigUInt(exactly: cns)!, "toCNS(\(value)) clamps negatives to zero")
        }
        XCTAssertEqual(PerplService.fromCNS(1_500_000), 1.5)
        XCTAssertEqual(PerplExchange.fromCNS(BigInt(-2_250_000)), -2.25)
        XCTAssertEqual(PerplExchange.units(.nan, decimals: 6), 0)
        XCTAssertEqual(PerplExchange.units(.infinity, decimals: 6), 0)
    }

    // MARK: Decoding live contract output

    func testPerpetualInfoParsing() {
        for (i, id) in marketIds.enumerated() {
            let m = market(id)
            let expected = f["chain"]["decoded"]["perpetualInfo\(id)"]
            XCTAssertEqual(m.id, id)
            XCTAssertTrue(m.symbol.hasPrefix(PerplService.markets[i].symbol), "\(m.symbol) is the contract's symbol for \(PerplService.markets[i].symbol)")
            XCTAssertEqual(m.symbol, expected["symbol"].string!)
            XCTAssertEqual(m.name, PerplService.markets[i].name)
            XCTAssertEqual(m.priceDecimals, Int(expected["priceDecimals"].string!)!)
            XCTAssertEqual(m.lotDecimals, Int(expected["lotDecimals"].string!)!)
            XCTAssertGreaterThan(m.mark, 0)
            XCTAssertEqual(m.mark, Double(expected["markPNS"].string!)! / pow(10, Double(m.priceDecimals)))
            XCTAssertEqual(m.last, Double(expected["lastPNS"].string!)! / pow(10, Double(m.priceDecimals)))
            XCTAssertEqual(m.oracle, Double(expected["oraclePNS"].string!)! / pow(10, Double(m.priceDecimals)))
            XCTAssertEqual(m.markTimestamp, Int(expected["markTimestamp"].string!)!)
            XCTAssertEqual(m.longOI, Double(expected["longOpenInterestLNS"].string!)! / pow(10, Double(m.lotDecimals)))
            XCTAssertEqual(m.shortOI, Double(expected["shortOpenInterestLNS"].string!)! / pow(10, Double(m.lotDecimals)))
            XCTAssertEqual(m.fundingRatePct100k, Int(expected["fundingRatePct100k"].number!))
            XCTAssertEqual(m.status, Int(expected["status"].number!))
            XCTAssertEqual(m.basePricePNS, BigUInt(expected["basePricePNS"].string!)!)
            XCTAssertEqual(m.numOrders, Int(expected["numOrders"].string!)!)
            // Only market 10 has a margin read in the fixture; the others are unknown, never guessed.
            if let initial = m.initMarginFraction, let maintenance = m.maintMarginFraction {
                XCTAssertGreaterThan(initial, 0)
                XCTAssertLessThan(initial, 1)
                XCTAssertGreaterThan(maintenance, 0)
                XCTAssertLessThan(maintenance, 1)
            } else {
                XCTAssertNotEqual(id, 10)
                XCTAssertNil(m.initMarginFraction)
                XCTAssertNil(m.maintMarginFraction)
            }
        }
        XCTAssertEqual(market(1).symbol, "BTC")
        XCTAssertEqual(market(10).symbol, "MON")
        XCTAssertEqual(market(20).symbol, "ETH")
    }

    func testMarginFractions() {
        let values = f["chain"]["decoded"]["marginFractions10"].array!.map { Double($0.string!)! }
        let mon = market(10)
        XCTAssertEqual(mon.initMarginFraction, 100 / values[0])
        XCTAssertEqual(mon.maintMarginFraction, 100 / values[1])
        XCTAssertEqual(mon.initMarginFraction!, 0.1, accuracy: 1e-12)
        XCTAssertEqual(mon.maintMarginFraction!, 0.05, accuracy: 1e-12)
        // Without a margin read the fractions are unknown, never a guessed 10% / 5% (which would understate the risk
        // on the 10% maintenance markets), so no liquidation price is computed.
        let btc = market(1)
        XCTAssertNil(btc.initMarginFraction)
        XCTAssertNil(btc.maintMarginFraction)
        XCTAssertEqual(btc.maxLeverage, 1)
        XCTAssertNil(PerplService.liquidationPrice(side: .long, entry: 100, size: 2, margin: 20, premium: 0, maintenanceFraction: btc.maintMarginFraction))
        XCTAssertNil(PerplService.liquidationPrice(side: .long, entry: 100, size: 2, margin: 20, premium: 0, maintenanceFraction: 0))
        // A zero divisor is unknown too, rather than dividing by zero.
        let info = try! ABI.decode(hex(f["chain"]["perpetualInfo"]["10"]["data"].string!), PerplExchange.Returns.perpetualInfo)[0]
        let zero = PerplExchange.market(id: 10, info: info, margins: [.uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0)])
        XCTAssertNil(zero.initMarginFraction)
        XCTAssertNil(zero.maintMarginFraction)
    }

    func testMarketsThroughMulticall() async throws {
        installMarkets()
        let markets = try await makeService().markets()
        XCTAssertEqual(markets.map(\.id), marketIds)
        XCTAssertEqual(markets.map(\.symbol).prefix(3), ["BTC", "MON", "ETH"])
        XCTAssertEqual(markets[1].initMarginFraction!, 0.1, accuracy: 1e-12)
        XCTAssertEqual(markets[1].maintMarginFraction!, 0.05, accuracy: 1e-12)
        XCTAssertNil(markets[0].maintMarginFraction, "margin read failed inside aggregate3: unknown, not a guess")
        XCTAssertEqual(PerplService.markets.map(\.id), [1, 10, 20, 31, 40, 50, 60, 70, 80, 90], "every live Perpl market")
        XCTAssertEqual(PerplMockTransport.aggregateSizes.sorted(), [10, 10], "one multicall for infos, one for margins")
        XCTAssertEqual(PerplMockTransport.unknownCalls.count, 13, "the fixture has no reads for 60-90 and margins only for 10")

        // A subset keeps the requested order, and an unknown market is simply left out.
        let subset = try await makeService().markets(ids: [50, 999, 1])
        XCTAssertEqual(subset.map(\.id), [50, 1])
    }

    func testAccountNotFoundReturnsNil() async throws {
        install(f["chain"]["accountByAddrCollateral"])
        install(f["chain"]["accountByAddrExchange"])
        XCTAssertEqual(f["chain"]["accountByAddrCollateral"]["error"]["code"].number, 3)
        XCTAssertTrue(f["chain"]["accountByAddrCollateral"]["error"]["data"].string!.hasPrefix("0x03a0e277"))
        let service = makeService()
        let none = try await service.account(Monad.ausd)
        XCTAssertNil(none)
        let alsoNone = try await service.account(exchange)
        XCTAssertNil(alsoNone)

        // Only Perpl's AccountNotFound revert means "no account" (RI-4); any other revert or failure surfaces as an error.
        XCTAssertTrue(PerplExchange.isAccountNotFound(RPCError(code: -32000, message: "execution reverted", data: "0x03A0E277" + String(repeating: "0", count: 64))))
        XCTAssertFalse(PerplExchange.isAccountNotFound(RPCError(code: -32000, message: "execution reverted")))
        XCTAssertFalse(PerplExchange.isAccountNotFound(RPCError(code: 3, message: "execution reverted", data: "0x")))
        XCTAssertFalse(PerplExchange.isAccountNotFound(RPCError(code: 3, message: "execution reverted", data: "0x08c379a0" + String(repeating: "0", count: 64))))
        XCTAssertFalse(PerplExchange.isAccountNotFound(RPCError(code: -32005, message: "rate limited")))
    }

    func testAccountParsingAndPositionBitmap() async throws {
        let bank1 = (BigUInt(1) << 1) | (BigUInt(1) << 10) | (BigUInt(1) << 252) | (BigUInt(1) << 253) | (BigUInt(1) << 255)
        let bank2 = BigUInt(1) | (BigUInt(1) << 255)
        let bank3 = BigUInt(1) << 7
        let bank4 = (BigUInt(1) << 0) | (BigUInt(1) << 255)
        XCTAssertEqual(PerplExchange.perpIds(bank1: bank1, bank2: bank2, bank3: bank3, bank4: bank4), [1, 10, 252, 253, 508, 516, 765, 1020], "bank1 holds 253 bits; its top three bits are not perp ids")
        XCTAssertEqual(PerplExchange.perpIds(bank1: 0, bank2: 0, bank3: 0, bank4: 0), [])

        let owner = Address(literal: "0x000000000000000000000000000000000000dEaD")
        install(PerplExchange.Signature.getAccountByAddr, [.address(owner)], returning: [
            .tuple([.uint(4638), .uint(1_000_000_000), .uint(250_000_000), .uint(0), .address(owner), .tuple([.uint(bank1), .uint(0), .uint(0), .uint(0)])]),
        ], types: PerplExchange.Returns.account)
        let account = try await makeService().account(owner)
        XCTAssertEqual(account, PerpAccount(accountId: 4638, balance: 1_000_000_000, locked: 250_000_000, frozen: false, positionPerpIds: [1, 10, 252]))

        install(PerplExchange.Signature.getAccountByAddr, [.address(Address.zero)], returning: [
            .tuple([.uint(0), .uint(0), .uint(0), .uint(0), .address(.zero), .tuple([.uint(0), .uint(0), .uint(0), .uint(0)])]),
        ], types: PerplExchange.Returns.account)
        let empty = try await makeService().account(.zero)
        XCTAssertNil(empty, "account id 0 is no account")

        install(PerplExchange.Signature.getAccountByAddr, [.address(exchange)], returning: [
            .tuple([.uint(7), .uint(5), .uint(0), .uint(1), .address(exchange), .tuple([.uint(0), .uint(0), .uint(0), .uint(0)])]),
        ], types: PerplExchange.Returns.account)
        let frozen = try await makeService().account(exchange)
        XCTAssertEqual(frozen?.frozen, true)
        XCTAssertEqual(frozen?.positionPerpIds, [])
    }

    func testOrderIdIndexWalk() {
        let raw = hex(f["chain"]["orderIdIndex10"]["data"].string!)
        let index = try! ABI.decode(raw, PerplExchange.Returns.orderIdIndex)
        let leaves = index[1].elements.map(\.uint)
        let expected = f["chain"]["decoded"]["orderIdIndex10"]
        XCTAssertEqual(leaves.count, Int(expected["leafCount"].number!))
        let ids = PerplExchange.orderIds(leaves: leaves)
        XCTAssertEqual(ids.count, Int(expected["totalIds"].number!))
        XCTAssertEqual(Array(ids.prefix(64)), expected["orderIds"].array!.map { Int($0.number!) })
        XCTAssertEqual(ids.count, Int(expected["numOrders"].string!)!, "the index holds one bit per live order")
        XCTAssertFalse(ids.contains(0), "order id 0 is never used")

        XCTAssertEqual(PerplExchange.orderIds(leaves: [0b111, 0b1, 0, BigUInt(1) << 255]), [1, 2, 256, 3 * 256 + 255])
        XCTAssertEqual(PerplExchange.orderIds(leaves: [1]), [], "bit 0 of leaf 0 is skipped")
        XCTAssertEqual(PerplExchange.orderIds(leaves: []), [])
    }

    func testPositionsParsing() async throws {
        installMarkets()
        install(f["chain"]["position10_1"])
        let service = makeService()
        let markets = try await service.markets()
        let mon = markets[1]

        // The live slot for account 1 on MON is empty (zero lot), so it is not a position.
        let decoded = f["chain"]["decoded"]["position10_1"]
        XCTAssertEqual(decoded["lotLNS"].string, "0")
        let live = try await service.positions(PerpAccount(accountId: 1, balance: 0, locked: 0, frozen: false, positionPerpIds: [10]), markets: markets)
        XCTAssertEqual(live, [])
        let noSlots = try await service.positions(PerpAccount(accountId: 1, balance: 0, locked: 0, frozen: false, positionPerpIds: []), markets: markets)
        XCTAssertEqual(noSlots, [])

        // A long with 42,036 MON at 0.026 backed by 100 AUSD carrying −1 AUSD of premium.
        func position(type: Int, lot: BigUInt, price: BigUInt, deposit: BigUInt, premium: BigInt, markPNS: BigUInt) -> [ABIValue] {
            [.tuple([.uint(4638), .uint(0), .uint(0), .uint(type), .uint(deposit), .uint(price), .uint(lot), .uint(103_000_000), .int(0), .int(0), .int(premium)]), .uint(markPNS), .bool(markPNS > 0)]
        }
        let long = PerplExchange.position(perp: mon, values: position(type: 0, lot: 42036, price: 26000, deposit: 100_000_000, premium: -1_000_000, markPNS: 26191))
        XCTAssertNotNil(long)
        XCTAssertEqual(long?.perpId, 10)
        XCTAssertEqual(long?.symbol, "MON")
        XCTAssertEqual(long?.side, .long)
        XCTAssertEqual(long?.size, 42036)
        XCTAssertEqual(long?.entry, 0.026)
        XCTAssertEqual(long?.mark, 0.026191)
        XCTAssertEqual(long?.margin, 100)
        XCTAssertEqual(long?.premium, -1)
        XCTAssertEqual(long!.unrealized, (0.026191 - 0.026) * 42036 - 1, accuracy: 1e-9)
        XCTAssertEqual(long!.notional, 42036 * 0.026191, accuracy: 1e-9)
        XCTAssertEqual(long!.leverage, 42036 * 0.026191 / 100, accuracy: 1e-9)
        XCTAssertEqual(long!.liquidation!, PerplService.liquidationPrice(side: .long, entry: 0.026, size: 42036, margin: 100, premium: -1, maintenanceFraction: mon.maintMarginFraction)!)

        let short = PerplExchange.position(perp: mon, values: position(type: 1, lot: 1000, price: 30000, deposit: 10_000_000, premium: 0, markPNS: 0))
        XCTAssertEqual(short?.side, .short)
        XCTAssertEqual(short?.mark, mon.mark, "a zero mark from getPosition falls back to the market's mark")
        XCTAssertEqual(short!.unrealized, (0.03 - mon.mark) * 1000, accuracy: 1e-9)
        XCTAssertEqual(short?.leverage, 1000 * mon.mark / 10)

        let empty = PerplExchange.position(perp: mon, values: position(type: 0, lot: 0, price: 26000, deposit: 100_000_000, premium: 0, markPNS: 26191))
        XCTAssertNil(empty)

        // Through the service: one real (empty) slot, one synthetic position, one market the list doesn't hold.
        install(PerplExchange.Signature.getPosition, [.uint(10), .uint(4638)], returning: position(type: 0, lot: 42036, price: 26000, deposit: 100_000_000, premium: -1_000_000, markPNS: 26191), types: PerplExchange.Returns.position)
        install(PerplExchange.Signature.getPosition, [.uint(999), .uint(4638)], returning: position(type: 0, lot: 5, price: 1, deposit: 1, premium: 0, markPNS: 1), types: PerplExchange.Returns.position)
        let account = PerpAccount(accountId: 4638, balance: 0, locked: 0, frozen: false, positionPerpIds: [1, 10, 999])
        // 999's market can't be read: an error, never a list that silently leaves the position out.
        do {
            _ = try await service.positions(account, markets: markets)
            XCTFail("a position in an unreadable market was dropped")
        } catch {}
        // Once its market reads (MON's info stands in), the position is decoded with it and shown.
        let monInfo = try! ABI.decode(hex(f["chain"]["perpetualInfo"]["10"]["data"].string!), PerplExchange.Returns.perpetualInfo)
        install(PerplExchange.Signature.getPerpetualInfo, [.uint(999)], returning: monInfo, types: PerplExchange.Returns.perpetualInfo)
        // The slot on market 1 can't be read (nothing answers getPosition for it): an error, never a silent drop.
        do {
            _ = try await service.positions(account, markets: markets)
            XCTFail("a position slot that failed to read was dropped")
        } catch PerplError.malformedResponse(let what) {
            XCTAssertEqual(what, "position 1")
        }
        // Once it reads as an empty slot (zero lot), it is skipped: not a position.
        install(PerplExchange.Signature.getPosition, [.uint(1), .uint(4638)], returning: position(type: 0, lot: 0, price: 0, deposit: 0, premium: 0, markPNS: 0), types: PerplExchange.Returns.position)
        let positions = try await service.positions(account, markets: markets)
        XCTAssertEqual(positions.map(\.perpId), [10, 999])
        XCTAssertEqual(positions.first, long!)
        XCTAssertNil(positions.last?.liquidation, "no margin read for 999: unknown, not guessed")
    }

    func testLiquidationPriceMatchesTypeScript() {
        for c in f["liquidationCases"].array! {
            let side: PositionSide = c["side"].string == "long" ? .long : .short
            let result = PerplService.liquidationPrice(side: side, entry: c["entry"].number!, size: c["size"].number!, margin: c["margin"].number!, premium: c["premium"].number!, maintenanceFraction: c["maintFrac"].number!)
            if let expected = c["expected"].number {
                XCTAssertEqual(result, expected, "\(c)")
            } else {
                XCTAssertNil(result, "\(c)")
            }
        }
        XCTAssertEqual(PerplService.liquidationPrice(side: .long, entry: 100, size: 2, margin: 20, premium: 0, maintenanceFraction: 0.05), 95)
        XCTAssertEqual(PerplService.liquidationPrice(side: .short, entry: 100, size: 2, margin: 20, premium: 0, maintenanceFraction: 0.05), 105)
        XCTAssertEqual(PerplService.liquidationPrice(side: .long, entry: 1, size: 1, margin: 100, premium: 0, maintenanceFraction: 0.05), 0, "never below zero")
        XCTAssertNil(PerplService.liquidationPrice(side: .long, entry: 1, size: 0, margin: 1, premium: 0, maintenanceFraction: 0.05))
        XCTAssertNil(PerplService.liquidationPrice(side: .long, entry: 1, size: -1, margin: 1, premium: 0, maintenanceFraction: 0.05))
    }

    func testOpenOrdersThroughMulticall() async throws {
        installMarkets()
        install(f["chain"]["orderIdIndex10"])
        install(f["chain"]["order10"])
        let decodedOrder = f["chain"]["decoded"]["order10"]
        let ownerId = Int(decodedOrder["accountId"].number!)
        let orderId = Int(f["chain"]["order10"]["orderId"].number!)
        let account = PerpAccount(accountId: ownerId, balance: 0, locked: 0, frozen: false, positionPerpIds: [])

        // The account holds a lock on MON and ETH; ETH's index is synthetic with 300 live ids to exercise chunking.
        for id in marketIds {
            let locks: ABIValue = id == 10 || id == 20 ? .array([.tuple([.uint(1), .uint(0), .uint(0), .uint(0), .uint(41890), .uint(0)])]) : .array([])
            install(PerplExchange.Signature.getPerpOrderLocks, [.uint(ownerId), .uint(id)], returning: [locks], types: PerplExchange.Returns.orderLocks)
        }
        let leaf0 = (BigUInt(1) << 256) - 1 // bits 1…255 → 255 ids
        let leaf1 = (BigUInt(1) << 45) - 1 // 45 ids
        install(PerplExchange.Signature.getOrderIdIndex, [.uint(20)], returning: [.uint(0), .array([.uint(leaf0), .uint(leaf1)]), .uint(300)], types: PerplExchange.Returns.orderIdIndex)
        // One ETH order belongs to the account, one to somebody else.
        let eth = market(20)
        install(PerplExchange.Signature.getOrder, [.uint(20), .uint(300)], returning: [.tuple([.uint(ownerId), .uint(PerpOrderType.closeLong.rawValue), .uint(1234), .uint(2500), .uint(0), .uint(103_260_000), .uint(1000), .uint(300), .uint(0), .uint(0), .uint(300)])], types: PerplExchange.Returns.order)
        install(PerplExchange.Signature.getOrder, [.uint(20), .uint(299)], returning: [.tuple([.uint(ownerId + 1), .uint(0), .uint(1), .uint(1), .uint(0), .uint(1), .uint(100), .uint(299), .uint(0), .uint(0), .uint(300)])], types: PerplExchange.Returns.order)

        let service = makeService()
        let markets = try await service.markets()
        PerplMockTransport.aggregateSizes = []
        let orders = try await service.openOrders(account, markets: markets)

        let monTotal = Int(f["chain"]["decoded"]["orderIdIndex10"]["totalIds"].number!)
        XCTAssertEqual(PerplMockTransport.aggregateSizes, [6, monTotal, 250, 50], "locks for six markets, then getOrder reads in chunks of 250")
        XCTAssertEqual(orders.count, 2)

        let mon = orders[0]
        XCTAssertEqual(mon.id, "10-\(orderId)")
        XCTAssertEqual(mon.perpId, 10)
        XCTAssertEqual(mon.orderId, orderId)
        XCTAssertEqual(mon.symbol, "MON")
        XCTAssertEqual(mon.type.rawValue, Int(decodedOrder["orderType"].number!))
        XCTAssertEqual(mon.side, mon.type == .openLong || mon.type == .closeShort ? .buy : .sell)
        XCTAssertEqual(mon.price, (Double(markets[1].basePricePNS) + decodedOrder["priceONS"].number!) / 1e6)
        XCTAssertEqual(mon.size, decodedOrder["lotLNS"].number!)
        XCTAssertEqual(mon.leverage, decodedOrder["leverageHdths"].number! / 100)
        XCTAssertEqual(mon.expiryBlock, Int(decodedOrder["expiryBlock"].number!))
        XCTAssertEqual(mon.reduceOnly, mon.type == .closeLong || mon.type == .closeShort)

        let close = orders[1]
        XCTAssertEqual(close.id, "20-300")
        XCTAssertEqual(close.type, .closeLong)
        XCTAssertEqual(close.side, .sell)
        XCTAssertEqual(close.reduceOnly, true)
        XCTAssertEqual(close.price, PerplExchange.scale(eth.basePricePNS + 1234, decimals: eth.priceDecimals))
        XCTAssertEqual(close.size, 2.5)
        XCTAssertEqual(close.leverage, 10)
        XCTAssertEqual(close.expiryBlock, 103_260_000)

        // No locks anywhere: no index walk at all.
        PerplMockTransport.aggregateSizes = []
        let stranger = PerpAccount(accountId: 1, balance: 0, locked: 0, frozen: false, positionPerpIds: [])
        install(f["chain"]["perpOrderLocks1_10"])
        let none = try await service.openOrders(stranger, markets: [markets[1]])
        XCTAssertEqual(none, [])
        XCTAssertEqual(PerplMockTransport.aggregateSizes, [1])
    }

    func testCollateralBalances() async throws {
        let owner = Address(literal: "0x000000000000000000000000000000000000dEaD")
        let balance = try ERC20.balanceOf(Perpl.collateral, owner).data.hexString
        let allowance = try ERC20.allowance(Perpl.collateral, owner: owner, spender: exchange).data.hexString
        PerplMockTransport.replies[balance] = .ok(BigUInt(123_456_789).word)
        PerplMockTransport.replies[allowance] = .ok(BigUInt(25_000_000).word)
        let result = try await makeService().collateral(of: owner)
        XCTAssertEqual(result.wallet, 123_456_789)
        XCTAssertEqual(result.allowance, 25_000_000)
        XCTAssertEqual(PerplMockTransport.aggregateSizes, [2])

        PerplMockTransport.replies[allowance] = .revert(Data())
        do {
            _ = try await makeService().collateral(of: owner)
            XCTFail("a failed read must not be reported as zero collateral")
        } catch {}
    }

    // MARK: Closing positions

    func testClosePositionPlan() {
        let mon = market(10)
        let service = makeService()
        let long = PerpPosition(perpId: 10, symbol: "MON", side: .long, size: 42036, entry: 0.026, mark: mon.mark, margin: 100, unrealized: 0, premium: 0, leverage: 11.0096, liquidation: nil, notional: 0)
        let plan = service.closePositionPlan(market: mon, position: long, slippageBps: 250)
        XCTAssertEqual(plan.count, 1)
        let desc = descTuple(in: plan[0].request!.data)
        XCTAssertEqual(desc[1].uint, 10)
        XCTAssertEqual(desc[2].uint, BigUInt(PerpOrderType.closeLong.rawValue), "closing a long sells reduce-only")
        XCTAssertEqual(desc[4].uint, BigUInt(exactly: PerplExchange.jsRound(mon.mark * (1 - 0.025) * 1e6)))
        XCTAssertEqual(desc[5].uint, 42036)
        XCTAssertEqual(desc[9].bool, true, "market order")
        XCTAssertEqual(desc[11].uint, 1100, "leverage rounds to 11x")
        XCTAssertEqual(try ABI.decode(plan[0].request!.data.dropFirst(4), try ABI.parameterTypes(of: PerplExchange.Signature.execOrders))[1].bool, true, "revertOnFail")

        let short = PerpPosition(perpId: 10, symbol: "MON", side: .short, size: 10, entry: 0.03, mark: mon.mark, margin: 0, unrealized: 0, premium: 0, leverage: 0.2, liquidation: nil, notional: 0)
        let shortDesc = descTuple(in: service.closePositionPlan(market: mon, position: short, slippageBps: 100)[0].request!.data)
        XCTAssertEqual(shortDesc[2].uint, BigUInt(PerpOrderType.closeShort.rawValue), "closing a short buys reduce-only")
        XCTAssertEqual(shortDesc[4].uint, BigUInt(exactly: PerplExchange.jsRound(mon.mark * (1 + 0.01) * 1e6)))
        XCTAssertEqual(shortDesc[11].uint, 100, "leverage never drops below 1x")

        // Part of it (the Close sheet's size chips): the same close for that size.
        let half = descTuple(in: service.closePositionPlan(market: mon, position: long, slippageBps: 250, size: 21018)[0].request!.data)
        XCTAssertEqual(half[5].uint, 21018)
        XCTAssertEqual(half[2].uint, BigUInt(PerpOrderType.closeLong.rawValue))
        XCTAssertEqual(half[11].uint, 1100)
    }

    /// The Close sheet's 25 / 50 / 75% chips close whole lots only (p4 spec #6): the position's lots × percent / 100,
    /// rounded down — so the size reviewed is the size sent — and nothing when that is less than one lot.
    func testCloseFractionSizesAreWholeLots() {
        XCTAssertEqual(PerplService.closeFractionSize(positionSize: 0.00054, lotDecimals: 5, percent: 50), 0.00027)
        XCTAssertEqual(PerplService.closeFractionSize(positionSize: 0.00036, lotDecimals: 5, percent: 75), 0.00027)
        XCTAssertEqual(PerplService.closeFractionSize(positionSize: 0.3, lotDecimals: 5, percent: 50), 0.15)
        XCTAssertEqual(PerplService.closeFractionSize(positionSize: 0.3, lotDecimals: 5, percent: 25), 0.075)
        XCTAssertEqual(PerplService.closeFractionSize(positionSize: 0.123, lotDecimals: 5, percent: 50), 0.0615)
        XCTAssertNil(PerplService.closeFractionSize(positionSize: 0.00001, lotDecimals: 5, percent: 25))
        XCTAssertEqual(PerplService.closeFractionSize(positionSize: 0.002, lotDecimals: 5, percent: 100), 0.002, "100% is the size as given")
        XCTAssertNil(PerplService.closeFractionSize(positionSize: 0, lotDecimals: 5, percent: 50))
        for lots in 1...2000 {
            let size = Double(lots) / 100_000
            for percent in [25, 50, 75] {
                let part = lots * percent / 100
                let chip = PerplService.closeFractionSize(positionSize: size, lotDecimals: 5, percent: percent)
                if part == 0 {
                    XCTAssertNil(chip, "\(lots) lots, \(percent)%")
                } else {
                    XCTAssertEqual(chip.map { Int(($0 * 100_000).rounded()) }, part, "\(lots) lots, \(percent)%")
                }
            }
        }
    }

    // MARK: Context

    func testContextParsing() async throws {
        PerplMockTransport.context = (200, Self.contextBody)
        let contexts = try await makeService().context()
        let expected = f["contextExpected"].array!
        XCTAssertEqual(contexts.count, expected.count)
        XCTAssertGreaterThanOrEqual(contexts.count, 6)
        for (c, e) in zip(contexts, expected) {
            XCTAssertEqual(c.id, Int(e["id"].number!))
            XCTAssertEqual(c.name, e["name"].string!)
            XCTAssertEqual(c.priceDecimals, Int(e["priceDecimals"].number!))
            XCTAssertEqual(c.sizeDecimals, Int(e["sizeDecimals"].number!))
            XCTAssertEqual(c.mark, e["mark"].number!, c.name)
            XCTAssertEqual(c.last, e["last"].number!, c.name)
            XCTAssertEqual(c.prev24h, e["prev24h"].number!, c.name)
            XCTAssertEqual(c.volume24h, e["volume24h"].number!, c.name)
            XCTAssertEqual(c.openInterest, e["openInterest"].number!, c.name)
            XCTAssertEqual(c.fundingRate, e["fundingRate"].number!, c.name)
            XCTAssertEqual(c.isOpen, e["isOpen"].bool!)
            XCTAssertGreaterThan(c.mark, 0)
        }
        XCTAssertEqual(contexts.map(\.name).prefix(6), ["BTC", "MON", "ETH", "SOL", "HYPE", "ZEC"])
        XCTAssertEqual(contexts[0].priceDecimals, 1)
        XCTAssertEqual(contexts[1].priceDecimals, 6)
        // Perpl's window for an order sent with `lb: 0`, which the order sheet's outcome deadline counts from.
        XCTAssertEqual(contexts[0].orderTTLBlocks, 20)
        XCTAssertEqual(PerplMockTransport.contextRequests.count, 1)
        XCTAssertEqual(PerplMockTransport.contextRequests.first?.absoluteString, "https://app.perpl.xyz/api/v1/pub/context")
    }

    func testContextErrors() async {
        PerplMockTransport.context = (503, Data("down".utf8))
        do {
            _ = try await makeService().context()
            XCTFail("expected an error")
        } catch let error as PerplError {
            XCTAssertEqual(error, .contextUnavailable(status: 503))
            XCTAssertEqual(error.errorDescription, "Perpl market data is unavailable (status 503).")
        } catch {
            XCTFail("unexpected \(error)")
        }

        PerplMockTransport.context = (200, Data("{\"markets\": [{\"id\": 1}]}".utf8))
        let partial = try? await makeService().context()
        XCTAssertEqual(partial, [], "markets without config and state are skipped")

        PerplMockTransport.context = (200, Data("{}".utf8))
        let empty = try? await makeService().context()
        XCTAssertEqual(empty, [])

        // A market without `order_ttl_blocks`: no window (the outcome deadline then counts Perpl's 20 blocks).
        PerplMockTransport.context = (200, Data(#"{"markets": [{"id": 1, "config": {"price_decimals": 1, "size_decimals": 5, "is_open": true}, "state": {"mrk": 816155}}]}"#.utf8))
        let windowless = try? await makeService().context()
        XCTAssertEqual(windowless?.count, 1)
        XCTAssertNil(windowless?.first?.orderTTLBlocks)
        XCTAssertEqual(PerplOutcomeDeadline(ackHead: 100, ttlBlocks: windowless?.first?.orderTTLBlocks, ackAt: Date()).block, 125)

        PerplMockTransport.context = (200, Data("not json".utf8))
        do {
            _ = try await makeService().context()
            XCTFail("expected an error")
        } catch let error as PerplError {
            XCTAssertEqual(error, .malformedResponse("market context"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

// MARK: - Replaying transport

/// Serves JSON-RPC and Perpl REST responses from a table so the service's real network code runs against the
/// recorded fixtures. Calls inside `aggregate3` are looked up individually, exactly as Multicall3 would run them.
final class PerplMockTransport: URLProtocol {
    enum Reply {
        case ok(Data)
        case revert(Data)
    }

    static var replies: [String: Reply] = [:]
    static var context: (status: Int, body: Data) = (200, Data())
    static var aggregateSizes: [Int] = []
    static var unknownCalls: [String] = []
    static var contextRequests: [URL] = []

    static func reset() {
        replies = [:]
        context = (200, Data())
        aggregateSizes = []
        unknownCalls = []
        contextRequests = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PerplMockTransport.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let status: Int
        let body: Data
        if url.host == PerplService.restBase.host {
            Self.contextRequests.append(url)
            (status, body) = Self.context
        } else {
            status = 200
            body = Self.rpcResponse(for: Self.body(of: request))
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private static func rpcResponse(for body: Data) -> Data {
        let json = (try? JSONDecoder().decode(JSON.self, from: body)) ?? .null
        let response: JSON = json.array.map { .array($0.map(reply)) } ?? reply(json)
        return try! JSONEncoder().encode(response)
    }

    private static func reply(_ request: JSON) -> JSON {
        let id = request["id"]
        guard request["method"].string == "eth_call", let to = request["params"][0]["to"].string, let dataHex = request["params"][0]["data"].string, let data = Data(hex: dataHex) else {
            return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32601), "message": .string("Unsupported in mock")])])
        }
        if to.lowercased() == Multicall.address.hex {
            let inner = try! ABI.decode(data.dropFirst(4), "(address,bool,bytes)[]")[0].elements
            aggregateSizes.append(inner.count)
            let items: [ABIValue] = inner.map { call in
                switch lookup(call[2].bytes) {
                case .ok(let result): return .tuple([.bool(true), .bytes(result)])
                case .revert(let result): return .tuple([.bool(false), .bytes(result)])
                }
            }
            let encoded = try! ABI.encode([.array(items)], [.array(.tuple([.bool, .bytes]))])
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": .string(encoded.hexString)])
        }
        switch lookup(data) {
        case .ok(let result):
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": .string(result.hexString)])
        case .revert(let result):
            return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(3), "message": .string("execution reverted"), "data": .string(result.hexString)])])
        }
    }

    private static func lookup(_ calldata: Data) -> Reply {
        if let reply = replies[calldata.hexString] { return reply }
        unknownCalls.append(calldata.hexString)
        return .revert(Data())
    }
}
