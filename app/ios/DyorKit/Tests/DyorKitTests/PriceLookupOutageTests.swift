import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// A pool lookup that an outage cut short is never remembered as "no pool": the token is looked up again on the next
/// read, and the pool it had keeps pricing it meanwhile (security audit 2026-09-26, RS-12). Runs PriceService's real
/// RPCClient and Multicall code against a stub chain whose pool reads can be made to fail.
final class PriceLookupOutageTests: XCTestCase {
    private static let token = Token(address: Address(literal: "0x00000000000000000000000000000000000000aa"), symbol: "TKN", name: "Token", decimals: 6)
    private static let pool = Address(literal: "0x00000000000000000000000000000000000000bb")

    override func setUp() { PriceChainStub.reset(token: Self.token.address, pool: Self.pool) }

    private func service(_ clock: StubClock) -> PriceService {
        PriceService(rpc: RPCClient(url: URL(string: "https://rpc.example")!, session: PriceChainStub.session()), now: { clock.now })
    }

    func testAFailedLiquidityReadKeepsTheLastPoolAndLooksAgain() async throws {
        let clock = StubClock()
        let prices = service(clock)
        let first = try await prices.prices(for: [Self.token])
        XCTAssertEqual(try XCTUnwrap(first[Self.token.address]?.usd), 1, accuracy: 1e-9, "priced from its USDC pool")

        // The pool is due a fresh lookup, and the liquidity read fails: not "no pool".
        clock.now = clock.now.addingTimeInterval(PoolLookupCache<Int>().hitTTL + 1)
        PriceChainStub.failLiquidity = true
        let lookups = PriceChainStub.getPoolCalls
        let during = try await prices.prices(for: [Self.token])
        XCTAssertGreaterThan(PriceChainStub.getPoolCalls, lookups, "looked up again")
        XCTAssertEqual(try XCTUnwrap(during[Self.token.address]?.usd), 1, accuracy: 1e-9, "the last pool keeps pricing it through the outage")

        // Still due a lookup: the next read tries again at once, instead of waiting out a miss.
        let before = PriceChainStub.getPoolCalls
        _ = try await prices.prices(for: [Self.token])
        XCTAssertGreaterThan(PriceChainStub.getPoolCalls, before, "the failed lookup was not remembered")
    }

    func testAFirstLookupThatFailsIsNotAMiss() async throws {
        let clock = StubClock()
        let prices = service(clock)
        PriceChainStub.failLiquidity = true
        let during = try await prices.prices(for: [Self.token])
        XCTAssertNil(during[Self.token.address], "no pool known yet")
        let unknown = await prices.withoutPool([Self.token])
        XCTAssertTrue(unknown.isEmpty, "its price is unknown, not absent: a list says a read failed")

        // The chain answers again: the very next read finds the pool, with no miss to wait out.
        PriceChainStub.failLiquidity = false
        let after = try await prices.prices(for: [Self.token])
        XCTAssertEqual(try XCTUnwrap(after[Self.token.address]?.usd), 1, accuracy: 1e-9)
        let priced = await prices.withoutPool([Self.token])
        XCTAssertTrue(priced.isEmpty)
    }

    func testACompleteLookupWithNoLiquidityIsAMiss() async throws {
        let clock = StubClock()
        let prices = service(clock)
        PriceChainStub.emptyPool = true
        let none = try await prices.prices(for: [Self.token])
        XCTAssertNil(none[Self.token.address])
        // It simply has no price: a list names it and totals the rest, as no failure.
        let noPool = await prices.withoutPool([Self.token, .mon])
        XCTAssertEqual(noPool, [Self.token.address], "a token never looked up is not among them")
        // Remembered for a while: no lookup until the miss expires.
        let lookups = PriceChainStub.getPoolCalls
        _ = try await prices.prices(for: [Self.token])
        XCTAssertEqual(PriceChainStub.getPoolCalls, lookups)
        clock.now = clock.now.addingTimeInterval(PoolLookupCache<Int>().missTTL + 1)
        _ = try await prices.prices(for: [Self.token])
        XCTAssertGreaterThan(PriceChainStub.getPoolCalls, lookups)
    }
}

final class StubClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

/// A chain with one Uniswap v3 TKN/USDC pool (fee 3000): getPool finds it, `liquidity()` answers — or fails, or reads
/// zero — as the test says, `token0()` is TKN and `slot0()` prices it at 1 USDC. Every other read answers "nothing
/// there" (a zero address or zero liquidity).
final class PriceChainStub: URLProtocol {
    nonisolated(unsafe) static var failLiquidity = false
    nonisolated(unsafe) static var emptyPool = false
    nonisolated(unsafe) static var getPoolCalls = 0
    nonisolated(unsafe) private static var token = Address.zero
    nonisolated(unsafe) private static var pool = Address.zero

    static func reset(token: Address, pool: Address) {
        failLiquidity = false
        emptyPool = false
        getPoolCalls = 0
        self.token = token
        self.pool = pool
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PriceChainStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let json = (try? JSONDecoder().decode(JSON.self, from: Self.body(of: request))) ?? .null
        let response: JSON = json.array.map { .array($0.map(Self.reply)) } ?? Self.reply(json)
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(response))
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

    private static func result(_ id: JSON, _ data: Data) -> JSON {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": .string(data.hexString)])
    }

    private static func reply(_ request: JSON) -> JSON {
        let id = request["id"]
        switch request["method"].string {
        case "eth_blockNumber":
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": .string("0x1000000")])
        case "eth_getBlockByNumber":
            // One header for every block asked: the clock can't measure a pace from it, and keeps the fallback.
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["number": .string("0x1000000"), "timestamp": .string("0x6b49d200")])])
        case "eth_call":
            guard let dataHex = request["params"][0]["data"].string, let data = Data(hex: dataHex) else { break }
            let inner = try! ABI.decode(data.dropFirst(4), "(address,bool,bytes)[]")[0].elements
            let items: [ABIValue] = inner.map { call in
                let answer = Self.answer(to: call[0].address, call[2].bytes)
                return .tuple([.bool(answer != nil), .bytes(answer ?? Data())])
            }
            return result(id, try! ABI.encode([.array(items)], [.array(.tuple([.bool, .bytes]))]))
        default:
            break
        }
        return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32601), "message": .string("Unsupported in stub")])])
    }

    /// One inner call's return data, or nil for a call that reverts.
    private static func answer(to target: Address, _ calldata: Data) -> Data? {
        let selector = calldata.prefix(4)
        if selector == ABI.selector("getPool(address,address,uint24)") {
            getPoolCalls += 1
            let args = try! ABI.decode(calldata.dropFirst(4), "address,address,uint24")
            let ours = target == Uniswap.v3Factory && args[0].address == token && args[1].address == Monad.usdc && args[2].uint == 3000
            return try! ABI.encode([.address(ours ? pool : .zero)], "address")
        }
        if target == pool {
            if selector == ABI.selector("liquidity()") {
                if failLiquidity { return nil }
                return try! ABI.encode([.uint(emptyPool ? 0 : BigUInt(10).power(18))], "uint128")
            }
            if selector == ABI.selector("token0()") { return try! ABI.encode([.address(token)], "address") }
            if selector == ABI.selector("slot0()") {
                // sqrtPriceX96 = 2^96: one raw USDC per raw TKN, both 6 decimals, so 1 USDC per TKN.
                return try! ABI.encode([.uint(BigUInt(1) << 96), .int(0), .uint(0), .uint(0), .uint(0), .uint(0), .bool(true)],
                                       "uint160,int24,uint16,uint16,uint16,uint8,bool")
            }
            return nil
        }
        if selector == ABI.selector("getLiquidity(bytes32)") { return try! ABI.encode([.uint(0)], "uint128") }
        // No DyorHQ factory recorded the token: an empty record on every launchpad, Moment id 0 on every cohort.
        if selector == ABI.selector(LaunchpadABI.Factory.getLaunchedToken), let stack = DyorCoinRegistry.launchpads(live: .monadMainnet).first(where: { $0.factory == target }) {
            let legacy = stack.generation.legacyRecord
            return try! ABI.encode([.tuple(DyorCoinChain.record(nil, legacy: legacy))], LaunchpadABI.launchedTokenReturns(legacy: legacy))
        }
        if selector == ABI.selector(MomentsABI.Factory.momentIdByCoin) { return try! ABI.encode([.uint(0)], "uint256") }
        if selector == ABI.selector("getPair(address,address)") { return try! ABI.encode([.address(.zero)], "address") }
        return nil
    }
}
